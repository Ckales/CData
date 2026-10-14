import 'package:file_selector/file_selector.dart' show openFile;
import 'package:flutter/material.dart';

import 'connection_options.dart';
import 'mac_widgets.dart';
import 'src/rust/api/connections.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/options.dart';
import 'src/rust/api/schema.dart';
import 'theme.dart';

/// 连接页（Querious 的连接窗口）：左边收藏的连接，右边连接表单。
///
/// 连上之后由外面开工作区。已经有打开的连接时可以点「返回」回去。
class ConnectionScreen extends StatefulWidget {
  /// 按表单去连。成功返回 null，失败返回原因，显示在表单里。
  /// databases 是勾选的库；空列表表示不限制，侧栏列出服务器上的全部库
  final Future<String?> Function(
    ConnectionConfig config,
    String name,
    List<String> databases,
  ) onConnect;

  /// 用表单参数开一个临时会话，用来列库。SSH 主机确认由调用方处理
  final Future<BigInt> Function(ConnectionConfig config) openSession;

  /// 已经有打开的连接时才有，回到那个工作区
  final VoidCallback? onCancel;

  final VoidCallback onPreferences;

  /// 启动时就有的错误，比如偏好文件读不出来
  final String? startupError;

  const ConnectionScreen({
    super.key,
    required this.onConnect,
    required this.openSession,
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

  /// 选择器勾选的库。空表示还没选过，沿用 [_database] 里的单个默认库，侧栏不限制
  List<String> _databases = [];
  bool _listingDatabases = false;

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
    for (final controller in [
      _name,
      _host,
      _port,
      _user,
      _password,
      _database,
    ]) {
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

  /// 点左边一条收藏：填表单，密码从钥匙串取。钥匙串读失败（比如点了拒绝）返回 false
  Future<bool> _pick(SavedConnection connection) async {
    _name.text = connection.name;
    _host.text = connection.host;
    _port.text = connection.port.toString();
    _user.text = connection.user;
    _database.text = connection.database ?? '';
    _databases = List.of(connection.databases);
    final String? password;
    try {
      password = await loadPassword(id: connection.id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _savedId = connection.id;
          _options = connection.options;
          _sshSecrets = const [];
          _password.clear();
          _error = '从钥匙串读密码失败：$e';
        });
      }
      return false;
    }
    if (!mounted) return false;
    setState(() {
      _savedId = connection.id;
      _options = connection.options;
      // SSH 密码 / 口令不回到界面，连接时 core 按 savedId 去钥匙串取
      _sshSecrets = const [];
      // 钥匙串里没有就留空，让用户自己输一次 —— 不猜也不静默用旧值
      _password.text = password ?? '';
      _error = null;
    });
    return true;
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
      _databases = [];
      _options = defaultConnectionOptions();
      _sshSecrets = const [];
      _error = null;
    });
  }

  /// 选了 1 个库就用它当默认库；选了多个不指定默认库，只限制侧栏；没选则沿用旧的单个库名
  ({String? database, List<String> filter}) _databaseChoice() {
    if (_databases.isNotEmpty) {
      return (
        database: _databases.length == 1 ? _databases.first : null,
        filter: _databases,
      );
    }
    final typed = _database.text.trim();
    return (database: typed.isEmpty ? null : typed, filter: const []);
  }

  /// 用表单里的账号连上去，列出服务器上的库，勾选后记在这条连接上
  Future<void> _pickDatabases() async {
    if (_listingDatabases) return;
    final port = int.tryParse(_port.text.trim());
    if (port == null) {
      setState(() => _error = '端口要填数字：${_port.text}');
      return;
    }
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '主机地址不能为空');
      return;
    }
    setState(() {
      _listingDatabases = true;
      _error = null;
    });
    final config = ConnectionConfig(
      host: host,
      port: port,
      user: _user.text.trim(),
      password: _password.text,
      database: null,
      options: _options,
      sshSecrets: _sshSecrets,
      savedId: _savedId,
    );
    final BigInt sessionId;
    try {
      sessionId = await widget.openSession(config);
    } catch (e) {
      if (mounted) {
        setState(() {
          _listingDatabases = false;
          _error = '$e';
        });
      }
      return;
    }
    List<String> names;
    try {
      names = await listDatabases(sessionId: sessionId);
    } catch (e) {
      await closeSession(sessionId: sessionId);
      if (mounted) {
        setState(() {
          _listingDatabases = false;
          _error = '$e';
        });
      }
      return;
    }
    await closeSession(sessionId: sessionId);
    if (!mounted) return;
    setState(() => _listingDatabases = false);
    final initial = _databases.isNotEmpty
        ? _databases
        : (_database.text.trim().isEmpty ? const <String>[] : [_database.text.trim()]);
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (context) => _DatabaseMultiSelect(databases: names, initial: initial),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _databases = picked;
      _database.clear();
    });
  }

  /// id 用 user@host:port，同一个目标再存就是覆盖。
  /// 走 SSH 时 host 往往是隧道那头的 127.0.0.1，id 里带上第一跳，不同服务器才不会互相覆盖
  String get _connectionId {
    final hops = _options.ssh.hops;
    final via = hops.isEmpty
        ? ''
        : ' via ${hops.first.user}@${hops.first.host}';
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
    final choice = _databaseChoice();
    try {
      await saveConnection(
        connection: SavedConnection(
          id: id,
          name: _displayName,
          host: _host.text.trim(),
          port: port,
          user: _user.text.trim(),
          database: choice.database,
          databases: choice.filter,
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
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

  /// 双击收藏：填好表单直接连
  Future<void> _open(SavedConnection connection) async {
    final picked = await _pick(connection);
    if (!picked || !mounted) return;
    await _connect();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    final port = int.tryParse(_port.text.trim());
    if (port == null) {
      setState(() => _error = '端口要填数字：${_port.text}');
      return;
    }
    final choice = _databaseChoice();
    final config = ConnectionConfig(
      host: _host.text.trim(),
      port: port,
      user: _user.text.trim(),
      password: _password.text,
      database: choice.database,
      options: _options,
      sshSecrets: _sshSecrets,
      savedId: _savedId,
    );
    setState(() {
      _connecting = true;
      _error = null;
    });
    final error = await widget.onConnect(config, _displayName, choice.filter);
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
                ToolbarButton(
                  icon: Icons.chevron_left,
                  tooltip: '返回已打开的连接',
                  onPressed: onCancel,
                ),
                const SizedBox(width: 6),
              ],
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '连接',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: mac.text,
                    ),
                  ),
                  Text(
                    '选一条收藏的连接，或者新建一条',
                    style: TextStyle(fontSize: 11, color: mac.secondaryText),
                  ),
                ],
              ),
              const Spacer(),
              ToolbarButton(
                icon: Icons.settings_outlined,
                tooltip: '偏好设置',
                onPressed: widget.onPreferences,
              ),
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
                  onOpen: _open,
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
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(34, 28, 24, 24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '连接设置',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: mac.text,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                _savedId == null ? '配置一条新的 MySQL 连接' : _displayName,
                style: TextStyle(fontSize: 11, color: mac.secondaryText),
              ),
              const SizedBox(height: 22),
              Text(
                '基本信息',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: mac.tertiaryText,
                ),
              ),
              const SizedBox(height: 8),
              FormRow(
                label: '名称',
                labelWidth: 101,
                child: _field('conn-name', _name, hint: '留空用主机名'),
              ),
              FormRow(
                label: '主机地址',
                labelWidth: 101,
                child: _field('conn-host', _host),
              ),
              FormRow(
                label: '端口',
                labelWidth: 101,
                child: _field('conn-port', _port),
              ),
              FormRow(
                label: '用户名',
                labelWidth: 101,
                child: _field('conn-user', _user),
              ),
              FormRow(
                label: '密码',
                labelWidth: 101,
                child: _field(
                  'conn-password',
                  _password,
                  obscure: true,
                  hint: '收藏的连接从钥匙串取',
                ),
              ),
              FormRow(
                label: '数据库',
                labelWidth: 101,
                child: _databaseField(),
              ),
              FormRow(
                label: '高级选项',
                labelWidth: 101,
                child: Row(
                  children: [
                    OutlinedButton(
                      key: const ValueKey('conn-options'),
                      onPressed: _editOptions,
                      child: const Text('查看设置…'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        summary.isEmpty ? 'SSL、SSH 与超时设置' : summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: mac.secondaryText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.only(left: 109),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '密码保存在系统钥匙串中',
                        style: TextStyle(fontSize: 10, color: mac.tertiaryText),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _save,
                      child: Text(_savedId == null ? '保存到收藏' : '保存'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('conn-connect'),
                      onPressed: _connecting ? null : _connect,
                      child: Text(_connecting ? '连接中…' : '连接数据库　→'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _databaseField() {
    final label = _databases.isNotEmpty ? _databases.join('、') : _database.text.trim();
    final hint = _listingDatabases ? '正在读取库…' : '点击选择数据库（可选）';
    return SizedBox(
      height: 28,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('conn-database'),
          borderRadius: BorderRadius.circular(6),
          onTap: _listingDatabases ? null : _pickDatabases,
          child: InputDecorator(
            decoration: InputDecoration(
              hintText: label.isEmpty ? hint : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              suffixIcon: _listingDatabases
                  ? const Padding(
                      padding: EdgeInsets.all(6),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                    )
                  : const Icon(Icons.arrow_drop_down, size: 18),
              suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 24),
            ),
            child: label.isEmpty
                ? const SizedBox.shrink()
                : Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    String key,
    TextEditingController controller, {
    bool obscure = false,
    String? hint,
  }) {
    return SizedBox(
      height: 28,
      child: TextField(
        key: ValueKey(key),
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
        ),
        onSubmitted: (_) => _connect(),
      ),
    );
  }
}

/// 高级选项的一句话摘要，比如「SSH · SSL」；什么都没开是空串
String _optionsSummary(ConnectionOptions options) {
  final parts = <String>[];
  if (options.ssh.hops.isNotEmpty) {
    parts.add('SSH（${options.ssh.hops.length} 跳）');
  }
  if (options.ssl.mode != SslMode.disabled) parts.add('SSL');
  if (options.timeouts.querySecs != null) {
    parts.add('查询超时 ${options.timeouts.querySecs} 秒');
  }
  return parts.join(' · ');
}

Future<void> _showDeleteMenu(
  BuildContext context,
  Offset position,
  VoidCallback onDelete,
) async {
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
    items: [
      desktopMenuItem(
        value: 'delete',
        label: '删除',
        icon: Icons.delete_outline,
        destructive: true,
      ),
    ],
  );
  if (choice == 'delete') onDelete();
}

/// 列服务器上的库，勾选要带上的。空选择表示不限制
class _DatabaseMultiSelect extends StatefulWidget {
  final List<String> databases;
  final List<String> initial;

  const _DatabaseMultiSelect({required this.databases, required this.initial});

  @override
  State<_DatabaseMultiSelect> createState() => _DatabaseMultiSelectState();
}

class _DatabaseMultiSelectState extends State<_DatabaseMultiSelect> {
  late final Set<String> _selected = widget.initial.toSet();
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyword = _filter.text.trim().toLowerCase();
    final visible = <String>[];
    for (final name in widget.databases) {
      if (keyword.isEmpty || name.toLowerCase().contains(keyword)) visible.add(name);
    }
    return AlertDialog(
      title: const Text('选择数据库'),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _filter,
              autofocus: true,
              decoration: const InputDecoration(hintText: '过滤'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('没有匹配的库'))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final name = visible[index];
                        return CheckboxListTile(
                          dense: true,
                          value: _selected.contains(name),
                          title: Text(name, style: const TextStyle(fontSize: 13)),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (checked) {
                            setState(() {
                              if (checked == true) {
                                _selected.add(name);
                              } else {
                                _selected.remove(name);
                              }
                            });
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final picked = <String>[];
            for (final name in widget.databases) {
              if (_selected.contains(name)) picked.add(name);
            }
            Navigator.pop(context, picked);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _FavoriteList extends StatelessWidget {
  final List<SavedConnection> saved;
  final String? selectedId;
  final void Function(SavedConnection connection) onPick;
  final void Function(SavedConnection connection) onOpen;
  final VoidCallback onNew;
  final void Function(SavedConnection connection) onDelete;

  const _FavoriteList({
    required this.saved,
    required this.selectedId,
    required this.onPick,
    required this.onOpen,
    required this.onNew,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    SavedConnection? selected;
    for (final connection in saved) {
      if (connection.id == selectedId) selected = connection;
    }
    return Container(
      width: 255,
      decoration: BoxDecoration(
        color: mac.sidebar,
        border: Border(right: BorderSide(color: mac.separator)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Text(
              '已保存连接',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: mac.secondaryText,
              ),
            ),
          ),
          Expanded(
            child: saved.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Text(
                      '还没有保存的连接。填好右侧表单后可以加入收藏。',
                      style: TextStyle(fontSize: 11, color: mac.secondaryText),
                    ),
                  )
                : ListView.builder(
                    itemCount: saved.length,
                    itemBuilder: (context, index) {
                      final connection = saved[index];
                      final isSelected = connection.id == selectedId;
                      final foreground = isSelected
                          ? scheme.onPrimaryContainer
                          : mac.text;
                      final secondary = isSelected
                          ? scheme.onPrimaryContainer.withValues(alpha: 0.72)
                          : mac.secondaryText;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        child: Material(
                          color: isSelected
                              ? scheme.primaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                          child: InkWell(
                            key: ValueKey('saved-${connection.id}'),
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => onPick(connection),
                            onDoubleTap: () => onOpen(connection),
                            onSecondaryTapUp: (details) => _showDeleteMenu(
                              context,
                              details.globalPosition,
                              () => onDelete(connection),
                            ),
                            child: SizedBox(
                              height: 48,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        color: scheme.primary.withValues(
                                          alpha: isSelected ? 0.18 : 0.1,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Icon(
                                        Icons.dns_outlined,
                                        size: 14,
                                        color: scheme.primary,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            connection.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: foreground,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${connection.host}:${connection.port}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 9,
                                              color: secondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '删除',
                                      onPressed: () => onDelete(connection),
                                      icon: Icon(Icons.delete_outline, size: 15, color: secondary),
                                      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                                      padding: EdgeInsets.zero,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: mac.separator)),
            ),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: onNew,
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('新建连接'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: selected == null ? null : () => onDelete(selected!),
                  child: const Text('删除'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
