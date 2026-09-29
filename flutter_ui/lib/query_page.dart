import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'connection_screen.dart';
import 'src/rust/api/connections.dart';
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
  final bool rememberOpenConnections;

  const QueryPage({
    super.key,
    required this.preferences,
    required this.onPreferencesChanged,
    this.startupError,
    this.rememberOpenConnections = true,
  });

  @override
  State<QueryPage> createState() => _QueryPageState();
}

class _QueryPageState extends State<QueryPage> {
  final List<Workspace> _workspaces = [];
  // 菜单栏的「新建已连接标签」要找到当前工作区的状态
  final Map<Workspace, GlobalKey<WorkspaceViewState>> _workspaceKeys = {};
  int _active = 0;
  int _nextWorkspaceId = 1;

  /// 在工作区之上显示连接页（新开一条连接时）
  bool _connecting = false;

  bool get _showConnectionScreen => _workspaces.isEmpty || _connecting;

  @override
  void initState() {
    super.initState();
    if (widget.preferences.restoreConnections) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreConnections());
    }
  }

  Future<void> _restoreConnections() async {
    try {
      final ids = await openConnectionIds();
      final saved = await listConnections();
      final byId = {for (final connection in saved) connection.id: connection};
      final errors = <String>[];
      for (final id in ids) {
        if (!mounted) return;
        final connection = byId[id];
        if (connection == null) {
          errors.add('找不到收藏的连接 $id');
          continue;
        }
        final config = ConnectionConfig(
          host: connection.host,
          port: connection.port,
          user: connection.user,
          password: '',
          database: connection.database,
          options: connection.options,
          sshSecrets: const [],
          savedId: connection.id,
        );
        final error = await _openConnection(config, connection.name, remember: false);
        if (error != null) errors.add('${connection.name}：$error');
      }
      if (mounted && errors.isNotEmpty) _showError('恢复连接失败：${errors.join('；')}');
    } catch (e) {
      if (mounted) _showError('恢复连接失败：$e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _rememberConnections() async {
    if (!widget.rememberOpenConnections) return;
    final ids = <String>[];
    for (final workspace in _workspaces) {
      final id = workspace.config.savedId;
      if (id != null && !ids.contains(id)) ids.add(id);
    }
    try {
      await saveOpenConnectionIds(ids: ids);
    } catch (e) {
      if (mounted) _showError('记录打开的连接失败：$e');
    }
  }

  @override
  void dispose() {
    for (final workspace in _workspaces) {
      _closeWorkspace(workspace);
    }
    super.dispose();
  }

  /// 连上一条新连接：开侧栏会话，列一次库确认真的连得上，再开工作区。失败返回原因
  Future<String?> _connect(ConnectionConfig config, String name) => _openConnection(config, name, remember: true);

  Future<String?> _openConnection(ConnectionConfig config, String name, {required bool remember}) async {
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
    if (remember) await _rememberConnections();
    return null;
  }

  Future<void> _closeWorkspace(Workspace workspace) async {
    for (final tab in workspace.tabs) {
      await tab.close();
    }
    await closeSession(sessionId: workspace.schemaId);
  }

  /// 标签栏点了别的连接的标签：那条连接先选中这个标签，再整个工作区切过去
  void _switchTo(Workspace workspace, int tab) {
    _workspaceKeys[workspace]?.currentState?.selectTab(tab);
    setState(() => _active = _workspaces.indexOf(workspace));
  }

  Future<void> _disconnect(Workspace workspace) async {
    final activeWorkspace = _workspaces[_active];
    setState(() {
      final index = _workspaces.indexOf(workspace);
      _workspaces.remove(workspace);
      _workspaceKeys.remove(workspace);
      if (_workspaces.isEmpty) {
        _active = 0;
      } else if (activeWorkspace == workspace) {
        // 断开的是当前连接：切到标签栏上挨着它的那条
        _active = index.clamp(0, _workspaces.length - 1);
      } else {
        // 断开的是后台的连接（关了它最后一个标签）：留在当前连接
        _active = _workspaces.indexOf(activeWorkspace);
      }
    });
    await _rememberConnections();
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

  /// 新窗口就是再起一个 app 进程，各窗口的连接互不相干。
  // ponytail: 多进程代替多窗口，Dock 上会多一个图标；Flutter 多窗口 API 稳定后换成真窗口
  Future<void> _newWindow() async {
    try {
      if (Platform.isMacOS) {
        // resolvedExecutable 是 CData.app/Contents/MacOS/xxx，往上三层是 .app
        final bundle = File(Platform.resolvedExecutable).parent.parent.parent.path;
        await Process.run('open', ['-n', bundle]);
      } else {
        await Process.start(Platform.resolvedExecutable, [], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打开新窗口失败：$e')));
    }
  }

  /// macOS 菜单栏。工作区里的快捷键由工作区自己的 CallbackShortcuts 先接住，菜单只在焦点不在那里时响应
  List<PlatformMenuItem> _menus() {
    final showingWorkspace = !_showConnectionScreen;
    return [
      PlatformMenu(
        label: 'CData',
        menus: [
          const PlatformMenuItemGroup(members: [PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about)]),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: '偏好设置…',
                shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
                onSelected: _editPreferences,
              ),
            ],
          ),
          const PlatformMenuItemGroup(
            members: [PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu)],
          ),
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
            ],
          ),
          const PlatformMenuItemGroup(members: [PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit)]),
        ],
      ),
      PlatformMenu(
        label: '文件',
        menus: [
          PlatformMenuItem(
            label: '新建连接窗口',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
            onSelected: _newWindow,
          ),
          PlatformMenuItem(
            label: '新建连接标签',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyT, meta: true),
            onSelected: () => setState(() => _connecting = true),
          ),
          PlatformMenuItem(
            label: '新建已连接标签',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyT, meta: true, shift: true),
            // 连接页上没有「当前连接」，置灰
            onSelected: showingWorkspace
                ? () => _workspaceKeys[_workspaces[_active]]?.currentState?.duplicateTab()
                : null,
          ),
        ],
      ),
      const PlatformMenu(
        label: '窗口',
        menus: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
          PlatformMenuItemGroup(
            members: [PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront)],
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final page = _buildPage();
    // 只有 macOS 自带菜单栏的实现，其他平台没有 delegate
    if (defaultTargetPlatform != TargetPlatform.macOS) return page;
    return PlatformMenuBar(menus: _menus(), child: page);
  }

  Widget _buildPage() {
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
            key: _workspaceKeys.putIfAbsent(workspace, () => GlobalKey(debugLabel: 'workspace-${workspace.id}')),
            workspace: workspace,
            all: _workspaces,
            onSwitch: _switchTo,
            onCloseTab: (other, tab) {
              _workspaceKeys[other]?.currentState?.closeTab(tab);
              // 那条连接在后台，它自己 setState 刷不到当前工作区的标签栏
              setState(() {});
            },
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
