import 'package:file_selector/file_selector.dart' show openFile;
import 'package:flutter/material.dart';

import 'connection_options.dart';
import 'mac_widgets.dart';
import 'src/rust/api/connections.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/options.dart';
import 'theme.dart';

/// 连接页（Querious 的连接窗口）：左边收藏的连接，右边连接表单。
///
/// 连上之后由外面开工作区。已经有打开的连接时可以点「返回」回去。
class ConnectionScreen extends StatefulWidget {
  /// 按表单去连。成功返回 null，失败返回原因，显示在表单里
  final Future<String?> Function(ConnectionConfig config, String name) onConnect;

  /// 已经有打开的连接时才有，回到那个工作区
  final VoidCallback? onCancel;

  final VoidCallback onPreferences;

  /// 启动时就有的错误，比如偏好文件读不出来
  final String? startupError;

  const ConnectionScreen({
    super.key,
    required this.onConnect,
    required this.onPreferences,
    this.onCancel,
    this.startupError,
  });

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _name = TextEditingController();
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '3306');
  final _user = TextEditingController(text: 'root');
  // 密码不预填 —— 凭据不进源码
  final _password = TextEditingController();
  final _database = TextEditingController();

  /// SSL / 超时 / SSH。同一份对象一直传下去：FRB 生成的类比较列表字段用的是引用相等
  ConnectionOptions _options = defaultConnectionOptions();

  /// 这次输入的 SSH 密码 / 口令，和 hops 一一对应。空表示没输入，core 按 savedId 去钥匙串里找
  List<String?> _sshSecrets = const [];

  List<SavedConnection> _saved = [];

  /// 表单内容来自哪条收藏。新建时是 null
  String? _savedId;

  bool _connecting = false;
  late String? _error = widget.startupError;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  @override
  void dispose() {
    for (final controller in [_name, _host, _port, _user, _password, _database]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSaved() async {
    try {
      final saved = await listConnections();
      if (mounted) setState(() => _saved = saved);
    } catch (e) {
      if (mounted) setState(() => _error = '读取收藏的连接失败：$e');
    }
  }

  /// 点左边一条收藏：填表单，密码从钥匙串取
  Future<void> _pick(SavedConnection connection) async {
    _name.text = connection.name;
    _host.text = connection.host;
    _port.text = connection.port.toString();
    _user.text = connection.user;
    _database.text = connection.database ?? '';
    final password = await loadPassword(id: connection.id);
    if (!mounted) return;
    setState(() {
      _savedId = connection.id;
      _options = connection.options;
      // SSH 密码 / 口令不回到界面，连接时 core 按 savedId 去钥匙串取
      _sshSecrets = const [];
      // 钥匙串里没有就留空，让用户自己输一次 —— 不猜也不静默用旧值
      _password.text = password ?? '';
      _error = null;
    });
  }

  void _newConnection() {
    setState(() {
      _savedId = null;
      _name.clear();
      _host.text = '127.0.0.1';
      _port.text = '3306';
      _user.text = 'root';
      _password.clear();
      _database.clear();
      _options = defaultConnectionOptions();
      _sshSecrets = const [];
      _error = null;
    });
  }

  /// id 用 user@host:port，同一个目标再存就是覆盖。
  /// 走 SSH 时 host 往往是隧道那头的 127.0.0.1，id 里带上第一跳，不同服务器才不会互相覆盖
  String get _connectionId {
    final hops = _options.ssh.hops;
    final via = hops.isEmpty ? '' : ' via ${hops.first.user}@${hops.first.host}';
    return '${_user.text.trim()}@${_host.text.trim()}:${_port.text.trim()}$via';
  }

  /// 没起名就用主机名当标题：标题下面一行本来就是「用户@主机:端口」，再写一遍是重复
  String get _displayName {
    final name = _name.text.trim();
    return name.isEmpty ? _host.text.trim() : name;
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null) {
      setState(() => _error = '端口要填数字：${_port.text}');
      return;
    }
    final id = _connectionId;
    final database = _database.text.trim();
    try {
      await saveConnection(
        connection: SavedConnection(
          id: id,
          name: _displayName,
          host: _host.text.trim(),
          port: port,
          user: _user.text.trim(),
          database: database.isEmpty ? null : database,
          options: _options,
        ),
        // 密码单独进钥匙串，配置文件里一个字符都不存
        password: _password.text.isEmpty ? null : _password.text,
      );
      final hops = _options.ssh.hops;
      for (var i = 0; i < _sshSecrets.length; i++) {
        final secret = _sshSecrets[i];
        if (secret == null) continue;
        await saveSshSecret(id: id, hop: hops[i], secret: secret);
      }
      if (!mounted) return;
      setState(() {
        _savedId = id;
        _error = null;
      });
      await _loadSaved();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 删收藏会连钥匙串里的密码一起删掉，先确认
  Future<void> _delete(SavedConnection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除收藏的连接'),
        content: Text('删除「${connection.name}」？钥匙串里保存的密码会一起删掉。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await deleteConnection(id: connection.id);
      if (!mounted) return;
      if (_savedId == connection.id) _newConnection();
      await _loadSaved();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _editOptions() async {
    final result = await showConnectionOptionsDialog(
      context,
      initial: _options,
      pickFile: () async => (await openFile())?.path,
    );
    if (result == null || !mounted) return;
    setState(() {
      _options = result.options;
      _sshSecrets = result.sshSecrets;
    });
  }

  Future<void> _connect() async {
    if (_connecting) return;
    final port = int.tryParse(_port.text.trim());
    if (port == null) {
      setState(() => _error = '端口要填数字：${_port.text}');
      return;
    }
    final database = _database.text.trim();
    final config = ConnectionConfig(
      host: _host.text.trim(),
      port: port,
      user: _user.text.trim(),
      password: _password.text,
      database: database.isEmpty ? null : database,
      options: _options,
      sshSecrets: _sshSecrets,
      savedId: _savedId,
    );
    setState(() {
      _connecting = true;
      _error = null;
    });
    final error = await widget.onConnect(config, _displayName);
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final onCancel = widget.onCancel;
    return Scaffold(
      backgroundColor: mac.window,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MacToolbar(
            children: [
              if (onCancel != null) ...[
                ToolbarButton(icon: Icons.chevron_left, tooltip: '返回已打开的连接', onPressed: onCancel),
                const SizedBox(width: 6),
              ],
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('连接', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: mac.text)),
                  Text('选一条收藏的连接，或者新建一条', style: TextStyle(fontSize: 11, color: mac.secondaryText)),
                ],
              ),
              const Spacer(),
              ToolbarButton(icon: Icons.settings_outlined, tooltip: '偏好设置', onPressed: widget.onPreferences),
            ],
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FavoriteList(
                  saved: _saved,
                  selectedId: _savedId,
                  onPick: _pick,
                  onNew: _newConnection,
                  onDelete: _delete,
                ),
                Expanded(child: _buildForm(mac)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(MacColors mac) {
    final summary = _optionsSummary(_options);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _savedId == null ? '新建连接' : _displayName,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: mac.text),
              ),
              const SizedBox(height: 14),
              FormRow(label: '名称', child: _field('conn-name', _name, hint: '留空用主机名')),
              FormRow(label: '主机', child: _field('conn-host', _host)),
              FormRow(label: '端口', child: SizedBox(width: 90, child: _field('conn-port', _port))),
              FormRow(label: '用户', child: _field('conn-user', _user)),
              FormRow(label: '密码', child: _field('conn-password', _password, obscure: true, hint: '收藏的连接从钥匙串取')),
              FormRow(label: '数据库', child: _field('conn-database', _database, hint: '可选')),
              FormRow(
                label: '高级',
                child: Row(
                  children: [
                    OutlinedButton(
                      key: const ValueKey('conn-options'),
                      onPressed: _editOptions,
                      child: const Text('SSL、SSH、超时…'),
                    ),
                    const SizedBox(width: 8),
                    Text(summary.isEmpty ? '直连，不加密' : summary, style: TextStyle(fontSize: 12, color: mac.secondaryText)),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onErrorContainer),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('密码只存在系统钥匙串里', style: TextStyle(fontSize: 11, color: mac.tertiaryText)),
                  const Spacer(),
                  OutlinedButton(onPressed: _save, child: Text(_savedId == null ? '加入收藏' : '保存')),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('conn-connect'),
                    onPressed: _connecting ? null : _connect,
                    child: Text(_connecting ? '连接中…' : '连接'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String key, TextEditingController controller, {bool obscure = false, String? hint}) {
    return SizedBox(
      height: 26,
      child: TextField(
        key: ValueKey(key),
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(hintText: hint, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
        onSubmitted: (_) => _connect(),
      ),
    );
  }
}

/// 高级选项的一句话摘要，比如「SSH · SSL」；什么都没开是空串
String _optionsSummary(ConnectionOptions options) {
  final parts = <String>[];
  if (options.ssh.hops.isNotEmpty) parts.add('SSH（${options.ssh.hops.length} 跳）');
  if (options.ssl.mode != SslMode.disabled) parts.add('SSL');
  if (options.timeouts.querySecs != null) parts.add('查询超时 ${options.timeouts.querySecs} 秒');
  return parts.join(' · ');
}

class _FavoriteList extends StatelessWidget {
  final List<SavedConnection> saved;
  final String? selectedId;
  final void Function(SavedConnection connection) onPick;
  final VoidCallback onNew;
  final void Function(SavedConnection connection) onDelete;

  const _FavoriteList({
    required this.saved,
    required this.selectedId,
    required this.onPick,
    required this.onNew,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    SavedConnection? selected;
    for (final connection in saved) {
      if (connection.id == selectedId) selected = connection;
    }
    return Container(
      width: 240,
      decoration: BoxDecoration(color: mac.sidebar, border: Border(right: BorderSide(color: mac.separator))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text('收藏', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: mac.tertiaryText)),
          ),
          Expanded(
            child: saved.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('还没有收藏的连接。填好右边的表单，点「加入收藏」', style: TextStyle(fontSize: 12, color: mac.secondaryText)),
                  )
                : ListView(
                    children: [
                      for (final connection in saved)
                        SidebarItem(
                          key: ValueKey('saved-${connection.id}'),
                          icon: Icons.dns_outlined,
                          iconColor: mac.databaseIcon,
                          label: connection.name,
                          selected: connection.id == selectedId,
                          onTap: () => onPick(connection),
                        ),
                    ],
                  ),
          ),
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: mac.separator))),
            child: Row(
              children: [
                _FooterButton(icon: Icons.add, tooltip: '新建连接', onPressed: onNew),
                _FooterButton(
                  icon: Icons.remove,
                  tooltip: '删除选中的收藏',
                  onPressed: selected == null ? null : () => onDelete(selected!),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _FooterButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 24,
          height: 20,
          child: Icon(icon, size: 14, color: onPressed == null ? mac.tertiaryText.withValues(alpha: 0.5) : mac.secondaryText),
        ),
      ),
    );
  }
}
