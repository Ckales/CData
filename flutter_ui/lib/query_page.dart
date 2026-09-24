import 'package:flutter/material.dart';

import 'connection_screen.dart';
import 'preferences_dialog.dart';
import 'query_tab.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/options.dart';
import 'src/rust/api/preferences.dart' as prefs;
import 'src/rust/api/schema.dart';
import 'workspace.dart';

/// 应用的根页面：没连接时是连接页，连上之后是工作区（Querious 的一个窗口）。
///
/// 可以同时开多条连接，每条一个工作区，都留在树上；标题菜单里切换。
/// 连接页随时能叫出来新开一条，再点「返回」回到原来的工作区。
class QueryPage extends StatefulWidget {
  final prefs.Preferences preferences;

  /// 偏好保存成功后调，由外层换主题等
  final void Function(prefs.Preferences preferences) onPreferencesChanged;

  /// 启动时就有的错误，比如偏好文件读不出来
  final String? startupError;

  const QueryPage({
    super.key,
    required this.preferences,
    required this.onPreferencesChanged,
    this.startupError,
  });

  @override
  State<QueryPage> createState() => _QueryPageState();
}

class _QueryPageState extends State<QueryPage> {
  final List<Workspace> _workspaces = [];
  int _active = 0;
  int _nextWorkspaceId = 1;

  /// 在工作区之上显示连接页（新开一条连接时）
  bool _connecting = false;

  bool get _showConnectionScreen => _workspaces.isEmpty || _connecting;

  @override
  void dispose() {
    for (final workspace in _workspaces) {
      _closeWorkspace(workspace);
    }
    super.dispose();
  }

  /// 连上一条新连接：开侧栏会话，列一次库确认真的连得上，再开工作区。失败返回原因
  Future<String?> _connect(ConnectionConfig config, String name) async {
    final BigInt sessionId;
    try {
      sessionId = await openSessionTrusting(config, _confirmHostKey);
    } catch (e) {
      return '$e';
    }
    // 直连时开会话只建池，真正的 TCP 连接等到第一次查询；列一次库把连不上、密码错这些问题当场报出来
    try {
      await listDatabases(sessionId: sessionId);
    } catch (e) {
      await closeSession(sessionId: sessionId);
      return '$e';
    }
    if (!mounted) {
      await closeSession(sessionId: sessionId);
      return null;
    }
    setState(() {
      _workspaces.add(Workspace(id: _nextWorkspaceId++, name: name, config: config, schemaId: sessionId));
      _active = _workspaces.length - 1;
      _connecting = false;
    });
    return null;
  }

  Future<void> _closeWorkspace(Workspace workspace) async {
    for (final tab in workspace.tabs) {
      await tab.close();
    }
    await closeSession(sessionId: workspace.schemaId);
  }

  Future<void> _disconnect(Workspace workspace) async {
    setState(() {
      _workspaces.remove(workspace);
      _active = _workspaces.isEmpty ? 0 : _active.clamp(0, _workspaces.length - 1);
    });
    await _closeWorkspace(workspace);
  }

  /// 没见过的 SSH 主机：把指纹给用户看，信任了才写进 known_hosts。指纹不符不走这里，直接报错
  Future<bool> _confirmHostKey(HostKeyIssue issue) async {
    final trusted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('第一次连接这台 SSH 主机'),
        content: SelectableText(
          '${issue.host}:${issue.port}\n${issue.algorithm}  ${issue.fingerprint}\n\n'
          '请和服务器管理员给的指纹核对。信任后会写进 ~/.ssh/known_hosts。',
          style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('信任并连接')),
        ],
      ),
    );
    return trusted ?? false;
  }

  Future<void> _editPreferences() async {
    final updated = await showPreferencesDialog(
      context,
      initial: widget.preferences,
      save: (preferences) => prefs.savePreferences(preferences: preferences),
    );
    if (updated != null) widget.onPreferencesChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final connectionScreen = ConnectionScreen(
      onConnect: _connect,
      onPreferences: _editPreferences,
      onCancel: _workspaces.isEmpty ? null : () => setState(() => _connecting = false),
      startupError: widget.startupError,
    );
    if (_workspaces.isEmpty) return connectionScreen;

    return IndexedStack(
      // 连接页排在最后；工作区都留在树上，切回来标签、结果、编辑器内容都还在
      index: _showConnectionScreen ? _workspaces.length : _active,
      children: [
        for (final workspace in _workspaces)
          WorkspaceView(
            key: ValueKey('workspace-${workspace.id}'),
            workspace: workspace,
            others: [
              for (final other in _workspaces)
                if (other != workspace) other,
            ],
            onSwitch: (other) => setState(() => _active = _workspaces.indexOf(other)),
            onNewConnection: () => setState(() => _connecting = true),
            onDisconnect: () => _disconnect(workspace),
            onPreferences: _editPreferences,
            maxRows: () => widget.preferences.maxRows,
            editorFontSize: widget.preferences.editorFontSize.toDouble(),
            confirmHostKey: _confirmHostKey,
          ),
        connectionScreen,
      ],
    );
  }
}
