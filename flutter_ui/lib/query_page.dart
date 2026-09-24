import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart' show openFile;

import 'connection_options.dart';
import 'data_source.dart';
import 'import_dialog.dart';
import 'preferences_dialog.dart';
import 'query_tab.dart';
import 'server_source.dart';
import 'server_status.dart';
import 'sql_library.dart';
import 'src/rust/api/connections.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/editor.dart';
import 'src/rust/api/options.dart';
import 'src/rust/api/preferences.dart' as prefs;
import 'src/rust/api/schema.dart';
import 'structure_editor.dart';
import 'structure_view.dart';
import 'table_sidebar.dart';
import 'user_admin.dart';
import 'user_source.dart';

/// 主窗口：连接栏 + 侧栏 + 多个查询标签。
///
/// 每个标签记着自己的连接参数，各有一个会话（结果集留在会话里），所以不同标签可以连不同的库。
/// 连接栏编辑的是当前标签的参数，点「连接」才生效。侧栏跟着当前标签的连接走，
/// 同一组参数的标签共用一个侧栏会话。
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
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '3306');
  final _user = TextEditingController(text: 'root');
  // 密码不预填 —— 凭据不进源码
  final _password = TextEditingController();
  final _database = TextEditingController();

  /// 连接栏上的 SSL / 超时 / SSH，和上面几个输入框一样是草稿，点「连接」才用到标签上。
  /// 同一份对象一直传下去：FRB 生成的类比较列表字段用的是引用相等，每次新建会被当成「改过了」
  ConnectionOptions _options = defaultConnectionOptions();

  /// 这次输入的 SSH 密码 / 口令，和 hops 一一对应。空表示没输入，core 去钥匙串里找
  List<String?> _sshSecrets = const [];

  final List<_TabEntry> _tabs = [];
  int _active = 0;
  int _nextTabNumber = 1;

  /// 侧栏、结构页、补全用的会话，一组连接参数一个。没有标签再用的就关掉
  final List<_SchemaSession> _schemaSessions = [];

  static const _library = RustSqlLibrary();

  List<SavedConnection> _saved = [];

  /// 快捷键挂在这个节点上。切标签时旧标签被 IndexedStack 设成不可聚焦，焦点会退到路由那一层、
  /// 跑到快捷键外面去，所以每次换标签都把焦点收回这里
  final _pageFocus = FocusNode(debugLabel: 'query-page');
  late String? _error = widget.startupError;

  @override
  void initState() {
    super.initState();
    _addTab(sql: 'SELECT * FROM big_rows ORDER BY id');
    _loadSaved();
  }

  @override
  void dispose() {
    _closeAllSessions();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _database.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  _TabEntry get _activeEntry => _tabs[_active];

  /// 新标签沿用当前标签的连接
  void _addTab({String sql = ''}) {
    final number = _nextTabNumber++;
    final current = _tabs.isEmpty ? null : _activeEntry;
    final entry = _TabEntry(
      id: number,
      title: '查询 $number',
      initialSql: sql,
      key: GlobalKey<QueryTabState>(),
      config: current?.config,
      savedId: current?.savedId,
    );
    entry.runner = RustQueryRunner(
      // 还没连过的标签，第一次运行时拿连接栏上的参数
      readConfig: () => entry.config ??= _readBarConfig(),
      maxRows: () => widget.preferences.maxRows,
      confirmHostKey: _confirmHostKey,
    );
    _tabs.add(entry);
    _active = _tabs.length - 1;
    _keepShortcutsAlive();
  }

  /// 等这一帧把旧标签设成不可聚焦之后再收回焦点
  void _keepShortcutsAlive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pageFocus.requestFocus();
    });
  }

  /// 关标签就关它的会话，否则连接一直挂着。最后一个关掉后留一个空标签
  Future<void> _closeTab(int index) async {
    final entry = _tabs[index];
    setState(() {
      _tabs.removeAt(index);
      if (_tabs.isEmpty) _addTab();
      _active = _active.clamp(0, _tabs.length - 1);
    });
    _showConfigInBar(_activeEntry.config);
    _keepShortcutsAlive();
    await entry.runner.close();
    await _pruneSchemaSessions();
  }

  void _selectTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    setState(() => _active = index);
    _showConfigInBar(_activeEntry.config);
    _keepShortcutsAlive();
  }

  /// 切到一个连过的标签，连接栏显示它的参数。没连过的保持栏上现有的内容
  void _showConfigInBar(ConnectionConfig? config) {
    if (config == null) return;
    _host.text = config.host;
    _port.text = config.port.toString();
    _user.text = config.user;
    _password.text = config.password;
    _database.text = config.database ?? '';
    setState(() {
      _options = config.options;
      _sshSecrets = config.sshSecrets;
    });
  }

  /// 标题取 SQL 第一行的开头
  void _retitle(_TabEntry entry, String sql) {
    final firstLine = sql.trim().split('\n').first;
    final title = firstLine.length > 24
        ? '${firstLine.substring(0, 24)}…'
        : firstLine;
    setState(() => entry.title = title.isEmpty ? '查询 ${entry.id}' : title);
  }

  _SchemaSession? _schemaFor(ConnectionConfig? config) {
    if (config == null) return null;
    for (final session in _schemaSessions) {
      if (session.config == config) return session;
    }
    return null;
  }

  Future<_SchemaSession> _ensureSchema(ConnectionConfig config) async {
    final existing = _schemaFor(config);
    if (existing != null) return existing;

    final id = await openSession(config: config);
    // 两个标签同时连上同一个库，只留一个会话
    final raced = _schemaFor(config);
    if (raced != null) {
      await closeSession(sessionId: id);
      return raced;
    }
    final created = _SchemaSession(config, id);
    if (mounted) setState(() => _schemaSessions.add(created));
    return created;
  }

  /// 某个标签查询成功后调：确保它的连接有侧栏会话，并重读补全目录
  Future<void> _onConnected(_TabEntry entry) async {
    final config = entry.config;
    if (config == null) return;
    final schema = await _ensureSchema(config);
    await _loadCatalog(schema, config);
  }

  /// ponytail: 每次查询成功都整库重读一遍列目录（一条 information_schema 查询），
  /// 这样建表、改表之后补全立刻跟上；几万列的大库再改成按需或增量
  Future<void> _loadCatalog(
    _SchemaSession schema,
    ConnectionConfig config,
  ) async {
    final database = config.database;
    if (database == null) return;
    try {
      await loadCatalog(sessionId: schema.id, database: database);
    } catch (e) {
      if (mounted) setState(() => _error = '读取补全目录失败：$e');
    }
  }

  /// 没有标签再用的连接，关掉它的侧栏会话
  Future<void> _pruneSchemaSessions() async {
    final stale = <_SchemaSession>[];
    for (final session in _schemaSessions) {
      var inUse = false;
      for (final entry in _tabs) {
        if (entry.config == session.config) inUse = true;
      }
      if (!inUse) stale.add(session);
    }
    if (stale.isEmpty) return;

    if (mounted) setState(() => _schemaSessions.removeWhere(stale.contains));
    for (final session in stale) {
      await closeSession(sessionId: session.id);
    }
  }

  /// 补全走这个标签那组连接的侧栏会话，它缓存着目录。还没连上时不补全
  Completion? _complete(_TabEntry entry, String sql, int cursor) {
    final schema = _schemaFor(entry.config);
    if (schema == null) return null;
    try {
      return completeSql(sessionId: schema.id, sql: sql, cursor: cursor);
    } catch (e) {
      // 补全失败不该打断输入，记下来方便排查
      debugPrint('补全失败（会话 ${schema.id}，光标 $cursor）：$e');
      return null;
    }
  }

  Future<void> _closeAllSessions() async {
    for (final session in _schemaSessions) {
      await closeSession(sessionId: session.id);
    }
    _schemaSessions.clear();
    for (final entry in _tabs) {
      await entry.runner.close();
    }
  }

  Future<void> _loadSaved() async {
    try {
      final saved = await listConnections();
      if (mounted) setState(() => _saved = saved);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 选中一条保存的连接：填字段，密码从钥匙串取，然后用在当前标签上。别的标签不动
  Future<void> _applySaved(SavedConnection connection) async {
    _host.text = connection.host;
    _port.text = connection.port.toString();
    _user.text = connection.user;
    _database.text = connection.database ?? '';
    _options = connection.options;
    // SSH 密码 / 口令不回到界面，连接时 core 按 savedId 去钥匙串取
    _sshSecrets = const [];

    final password = await loadPassword(id: connection.id);
    // 钥匙串里没有就留空，让用户自己输一次 —— 不猜也不静默用旧值
    _password.text = password ?? '';

    final entry = _activeEntry;
    entry.savedId = connection.id;
    await _applyConfig(entry, _readBarConfig());
  }

  /// 保存当前连接。id 用 user@host:port，同一个目标再存就是覆盖。
  /// 走 SSH 时 host 往往是隧道那头的 127.0.0.1，id 里带上第一跳，不同服务器才不会互相覆盖
  Future<void> _saveCurrent() async {
    final hops = _options.ssh.hops;
    final via = hops.isEmpty
        ? ''
        : ' via ${hops.first.user}@${hops.first.host}';
    final id =
        '${_user.text.trim()}@${_host.text.trim()}:${_port.text.trim()}$via';
    final database = _database.text.trim();

    try {
      await saveConnection(
        connection: SavedConnection(
          id: id,
          name: id,
          host: _host.text.trim(),
          port: int.parse(_port.text.trim()),
          user: _user.text.trim(),
          database: database.isEmpty ? null : database,
          options: _options,
        ),
        // 密码单独进钥匙串，配置文件里一个字符都不存
        password: _password.text.isEmpty ? null : _password.text,
      );
      for (var i = 0; i < _sshSecrets.length; i++) {
        final secret = _sshSecrets[i];
        if (secret == null) continue;
        await saveSshSecret(id: id, hop: hops[i], secret: secret);
      }
      if (!mounted) return;
      setState(() => _activeEntry.savedId = id);
      await _loadSaved();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 端口不是数字会抛 FormatException，调用方决定怎么提示
  ConnectionConfig _readBarConfig() {
    final database = _database.text.trim();
    return ConnectionConfig(
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      user: _user.text.trim(),
      password: _password.text,
      database: database.isEmpty ? null : database,
      options: _options,
      sshSecrets: _sshSecrets,
      savedId: _activeEntry.savedId,
    );
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('信任并连接'),
          ),
        ],
      ),
    );
    return trusted ?? false;
  }

  /// 连接栏上的参数和当前标签在用的不一样，提示点「连接」才生效
  bool get _barChanged {
    final config = _activeEntry.config;
    if (config == null) return false;
    try {
      return _readBarConfig() != config;
    } on FormatException {
      return true;
    }
  }

  /// 换一个标签的连接：关掉它的会话、清掉结果，下次运行按新参数开
  Future<void> _applyConfig(_TabEntry entry, ConnectionConfig config) async {
    setState(() => entry.config = config);
    await entry.key.currentState?.reset();
    await _pruneSchemaSessions();
  }

  /// 连接栏的「连接」：参数用到当前标签上并重新运行
  Future<void> _connect() async {
    final ConnectionConfig config;
    try {
      config = _readBarConfig();
    } on FormatException {
      setState(() => _error = '端口要填数字：${_port.text}');
      return;
    }
    setState(() => _error = null);

    final entry = _activeEntry;
    await _applyConfig(entry, config);
    await entry.key.currentState?.run();
  }

  /// 点侧栏的表 → 在当前标签里浏览这张表
  Future<void> _browseTable(String table) async {
    final sql = await browseSql(table: table);
    await _activeEntry.key.currentState?.runSql(sql);
  }

  /// 换库要重开会话：连接配置里带着 database。只换当前标签的库，侧栏直接跟过去
  Future<void> _switchDatabase(String database) async {
    final entry = _activeEntry;
    final config = entry.config;
    if (config == null) return;

    final switched = ConnectionConfig(
      host: config.host,
      port: config.port,
      user: config.user,
      password: config.password,
      database: database,
      options: config.options,
      sshSecrets: config.sshSecrets,
      savedId: config.savedId,
    );
    _database.text = database;
    await _applyConfig(entry, switched);
    final schema = await _ensureSchema(switched);
    await _loadCatalog(schema, switched);
  }

  Future<void> _editPreferences() async {
    final updated = await showPreferencesDialog(
      context,
      initial: widget.preferences,
      save: (preferences) => prefs.savePreferences(preferences: preferences),
    );
    if (updated != null) widget.onPreferencesChanged(updated);
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    const digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
    ];
    final count = _tabs.length;
    return {
      commandKey(LogicalKeyboardKey.keyT): () => setState(_addTab),
      commandKey(LogicalKeyboardKey.keyW): () => _closeTab(_active),
      commandKey(LogicalKeyboardKey.comma): _editPreferences,
      const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
          _selectTab((_active + 1) % count),
      const SingleActivator(
        LogicalKeyboardKey.tab,
        control: true,
        shift: true,
      ): () =>
          _selectTab((_active - 1 + count) % count),
      for (var i = 0; i < digits.length; i++)
        commandKey(digits[i]): () => _selectTab(i),
      // 和浏览器一样，9 是最后一个
      commandKey(LogicalKeyboardKey.digit9): () => _selectTab(count - 1),
    };
  }

  @override
  Widget build(BuildContext context) {
    final entry = _activeEntry;
    final schema = _schemaFor(entry.config);
    final database = entry.config?.database;
    final scheme = Theme.of(context).colorScheme;

    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        focusNode: _pageFocus,
        autofocus: true,
        child: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 只让连接栏跟着输入重绘，不带着整页
              ListenableBuilder(
                listenable: Listenable.merge([
                  _host,
                  _port,
                  _user,
                  _password,
                  _database,
                ]),
                builder: (context, _) => _ConnectionBar(
                  host: _host,
                  port: _port,
                  user: _user,
                  password: _password,
                  database: _database,
                  connected: schema != null,
                  changed: _barChanged,
                  onConnect: _connect,
                  saved: _saved,
                  savedId: entry.savedId,
                  onPickSaved: _applySaved,
                  onSave: _saveCurrent,
                  onPreferences: _editPreferences,
                  // 还没连上时没有会话可用，按钮置灰
                  onServerStatus: schema == null
                      ? null
                      : () => showServerStatus(
                          context,
                          source: schema.server,
                          serverLabel: '${schema.config.host}:${schema.config.port}',
                        ),
                  onUserAdmin: schema == null ? null : () => showUserAdmin(context, source: schema.users),
                  optionsSummary: _optionsSummary(_options),
                  onOptions: _editOptions,
                ),
              ),
              if (_error != null)
                Container(
                  color: scheme.errorContainer,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (schema != null)
                      TableSidebar(
                        // 数据源随会话建一次，每次重绘都新建的话侧栏会以为换了库，重读一遍
                        source: schema.source,
                        database: database ?? '',
                        onDatabaseChanged: _switchDatabase,
                        onTableSelected: _browseTable,
                        onShowStructure: (table) => showTableStructure(
                          context,
                          source: schema.source,
                          database: database ?? '',
                          table: table,
                          // 改表不增删表，侧栏清单不用刷；列变了，补全目录要重读
                          onAltered: () => _loadCatalog(schema, entry.config!),
                        ),
                        // 建表之后补全目录要多一张表；侧栏自己会重读并选中新表
                        onCreateTable: (database) async {
                          final created = await showTableCreator(context, source: schema.source, database: database);
                          if (created != null) await _loadCatalog(schema, entry.config!);
                          return created;
                        },
                        // 导入用侧栏的会话开自己独占的连接，不占标签的会话。
                        // 导完不自动重跑当前标签：标签里的 SQL 不一定和这张表有关，结果在对话框里看
                        onImport: (table) => showImportDialog(
                          context,
                          source: RustImportSource(schema.id),
                          database: database ?? '',
                          table: table,
                        ),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _TabStrip(
                            tabs: _tabs,
                            active: _active,
                            onSelect: _selectTab,
                            onClose: _closeTab,
                            onAdd: () => setState(_addTab),
                          ),
                          Expanded(
                            // 不在前台的标签也留着，切回来结果和编辑器内容都还在
                            child: IndexedStack(
                              index: _active,
                              children: [
                                for (final tab in _tabs)
                                  QueryTab(
                                    key: tab.key,
                                    runner: tab.runner,
                                    library: _library,
                                    tokenize: (sql) => tokenizeSql(sql: sql),
                                    initialSql: tab.initialSql,
                                    onRan: (sql) => _retitle(tab, sql),
                                    complete: (sql, cursor) =>
                                        _complete(tab, sql, cursor),
                                    onConnected: () => _onConnected(tab),
                                    editorFontSize: widget
                                        .preferences
                                        .editorFontSize
                                        .toDouble(),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
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
}

/// 连接栏「高级」按钮上显示用了哪些选项，没用就是空串
String _optionsSummary(ConnectionOptions options) {
  final parts = <String>[];
  if (options.ssh.hops.isNotEmpty) parts.add('SSH');
  if (options.ssl.mode != SslMode.disabled) parts.add('SSL');
  return parts.join(' · ');
}

bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

/// macOS 用 ⌘，其他平台用 Ctrl
SingleActivator commandKey(LogicalKeyboardKey key) {
  return SingleActivator(key, meta: _isMac, control: !_isMac);
}

/// 提示里显示的快捷键写法
String commandLabel(String key) => _isMac ? '⌘$key' : 'Ctrl+$key';

class _SchemaSession {
  final ConnectionConfig config;
  final BigInt id;
  final RustSchemaSource source;
  final RustServerSource server;
  final RustUserSource users;

  _SchemaSession(this.config, this.id)
    : source = RustSchemaSource(id),
      server = RustServerSource(id),
      users = RustUserSource(id);
}

class _TabEntry {
  final int id;
  String title;
  final String initialSql;
  final GlobalKey<QueryTabState> key;
  late final RustQueryRunner runner;

  /// 这个标签在用的连接参数。null 表示还没连过
  ConnectionConfig? config;

  /// 连接栏下拉框选中的保存连接
  String? savedId;

  _TabEntry({
    required this.id,
    required this.title,
    required this.initialSql,
    required this.key,
    required this.config,
    required this.savedId,
  });
}

class _TabStrip extends StatelessWidget {
  final List<_TabEntry> tabs;
  final int active;
  final void Function(int index) onSelect;
  final void Function(int index) onClose;
  final VoidCallback onAdd;

  const _TabStrip({
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 32,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final entry = tabs[index];
                final selected = index == active;
                final config = entry.config;
                return Tooltip(
                  message: config == null
                      ? '未连接'
                      : '${config.user}@${config.host}:${config.port}/${config.database ?? ''}'
                            '${config.options.ssh.hops.isEmpty ? '' : '（经 SSH ${config.options.ssh.hops.first.host}）'}',
                  waitDuration: const Duration(milliseconds: 600),
                  child: InkWell(
                    key: ValueKey('tab-${entry.id}'),
                    onTap: () => onSelect(index),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 220),
                      padding: const EdgeInsets.only(left: 12, right: 2),
                      decoration: BoxDecoration(
                        color: selected
                            ? scheme.surface
                            : scheme.surfaceContainerHighest,
                        border: Border(
                          bottom: BorderSide(
                            color: selected
                                ? scheme.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                          right: BorderSide(color: scheme.outlineVariant),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: selected ? FontWeight.w600 : null,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭标签（${commandLabel('W')}）',
                            iconSize: 13,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onClose(index),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: '新标签（${commandLabel('T')}）',
            iconSize: 16,
            onPressed: onAdd,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _ConnectionBar extends StatelessWidget {
  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController user;
  final TextEditingController password;
  final TextEditingController database;
  final bool connected;

  /// 栏上的参数改过、还没点「连接」
  final bool changed;
  final VoidCallback? onConnect;
  final List<SavedConnection> saved;
  final String? savedId;
  final void Function(SavedConnection connection) onPickSaved;
  final VoidCallback? onSave;
  final VoidCallback onPreferences;
  final VoidCallback? onServerStatus;
  final VoidCallback? onUserAdmin;
  final String optionsSummary;
  final VoidCallback onOptions;

  const _ConnectionBar({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.database,
    required this.connected,
    required this.changed,
    required this.onConnect,
    required this.saved,
    required this.savedId,
    required this.onPickSaved,
    required this.onSave,
    required this.onPreferences,
    required this.onServerStatus,
    required this.onUserAdmin,
    required this.optionsSummary,
    required this.onOptions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          if (saved.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 150,
                child: DropdownButtonFormField<String>(
                  // initialValue 只在第一次生效，切标签时靠换 key 让它显示新标签的选择
                  key: ValueKey('saved-$savedId'),
                  initialValue: savedId,
                  isDense: true,
                  isExpanded: true,
                  hint: const Text('已保存', style: TextStyle(fontSize: 11)),
                  style: TextStyle(fontSize: 12, color: scheme.onSurface),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  items: [
                    for (final connection in saved)
                      DropdownMenuItem(
                        value: connection.id,
                        child: Text(
                          connection.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) return;
                    for (final connection in saved) {
                      if (connection.id == id) {
                        onPickSaved(connection);
                        return;
                      }
                    }
                  },
                ),
              ),
            ),
          _Field(label: '主机', controller: host, width: 130),
          _Field(label: '端口', controller: port, width: 70),
          _Field(label: '用户', controller: user, width: 100),
          _Field(label: '密码', controller: password, width: 120, obscure: true),
          _Field(label: '数据库', controller: database, width: 130),
          Tooltip(
            message: 'SSL、超时、SSH 隧道',
            child: TextButton(
              onPressed: onOptions,
              child: Text(
                optionsSummary.isEmpty ? '高级…' : '高级 · $optionsSummary',
              ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            connected ? Icons.link : Icons.link_off,
            size: 16,
            color: connected ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: '用栏上的参数重新连接当前标签',
            child: OutlinedButton(
              onPressed: onConnect,
              child: const Text('连接'),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: '保存连接（密码进系统钥匙串）',
            child: OutlinedButton(onPressed: onSave, child: const Text('保存')),
          ),
          if (changed)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '参数已改，点「连接」生效',
                style: TextStyle(fontSize: 11, color: scheme.tertiary),
              ),
            ),
          const Spacer(),
          IconButton(
            tooltip: '服务器状态：进程、变量、状态计数、慢日志',
            onPressed: onServerStatus,
            icon: const Icon(Icons.monitor_heart_outlined, size: 18),
          ),
          IconButton(
            tooltip: '用户与权限',
            onPressed: onUserAdmin,
            icon: const Icon(Icons.manage_accounts_outlined, size: 18),
          ),
          IconButton(
            tooltip: '偏好设置（${commandLabel(',')}）',
            onPressed: onPreferences,
            icon: const Icon(Icons.settings_outlined, size: 18),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final double width;
  final bool obscure;

  const _Field({
    required this.label,
    required this.controller,
    required this.width,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        width: width,
        child: TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(fontSize: 11),
            isDense: true,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 8,
            ),
          ),
        ),
      ),
    );
  }
}
