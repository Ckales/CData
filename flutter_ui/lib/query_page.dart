import 'package:flutter/material.dart';

import 'data_source.dart';
import 'query_tab.dart';
import 'sql_library.dart';
import 'src/rust/api/connections.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/editor.dart';
import 'src/rust/api/schema.dart';
import 'structure_view.dart';
import 'table_sidebar.dart';

/// 主窗口：连接栏 + 侧栏 + 多个查询标签。
///
/// 每个标签有自己的会话（结果集留在会话里）；侧栏另用一个会话读库表清单。
/// 改了连接参数，所有会话一起关掉重开，不拿旧连接跑新库。
class QueryPage extends StatefulWidget {
  const QueryPage({super.key});

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

  final List<_TabEntry> _tabs = [];
  int _active = 0;
  int _nextTabNumber = 1;

  /// 侧栏和结构页用的会话。某个标签第一次查询成功后才开
  BigInt? _schemaSessionId;

  static const _library = RustSqlLibrary();

  List<SavedConnection> _saved = [];
  String? _savedId;
  String? _error;

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
    super.dispose();
  }

  void _addTab({String sql = ''}) {
    final number = _nextTabNumber++;
    _tabs.add(
      _TabEntry(
        id: number,
        title: '查询 $number',
        initialSql: sql,
        key: GlobalKey<QueryTabState>(),
        runner: RustQueryRunner(readConfig: _readConfig),
      ),
    );
    _active = _tabs.length - 1;
  }

  /// 关标签就关它的会话，否则连接一直挂着。最后一个关掉后留一个空标签
  Future<void> _closeTab(int index) async {
    final entry = _tabs[index];
    setState(() {
      _tabs.removeAt(index);
      if (_tabs.isEmpty) _addTab();
      _active = _active.clamp(0, _tabs.length - 1);
    });
    await entry.runner.close();
  }

  /// 标题取 SQL 第一行的开头
  void _retitle(_TabEntry entry, String sql) {
    final firstLine = sql.trim().split('\n').first;
    final title = firstLine.length > 24 ? '${firstLine.substring(0, 24)}…' : firstLine;
    setState(() => entry.title = title.isEmpty ? '查询 ${entry.id}' : title);
  }

  /// 某个标签查询成功后调：侧栏会话不存在就开一个，并重读补全目录
  Future<void> _onConnected() async {
    var id = _schemaSessionId;
    if (id == null) {
      id = await openSession(config: _readConfig());
      if (!mounted) return;
      setState(() => _schemaSessionId = id);
    }
    await _loadCatalog(id);
  }

  /// ponytail: 每次查询成功都整库重读一遍列目录（一条 information_schema 查询），
  /// 这样建表、改表之后补全立刻跟上；几万列的大库再改成按需或增量
  Future<void> _loadCatalog(BigInt sessionId) async {
    final database = _database.text.trim();
    if (database.isEmpty) return;
    try {
      await loadCatalog(sessionId: sessionId, database: database);
    } catch (e) {
      if (mounted) setState(() => _error = '读取补全目录失败：$e');
    }
  }

  /// 补全走侧栏的会话，它缓存着当前库的目录。还没连上时不补全
  Completion? _complete(String sql, int cursor) {
    final id = _schemaSessionId;
    if (id == null) return null;
    try {
      return completeSql(sessionId: id, sql: sql, cursor: cursor);
    } catch (e) {
      // 补全失败不该打断输入，记下来方便排查
      debugPrint('补全失败（会话 $id，光标 $cursor）：$e');
      return null;
    }
  }

  Future<void> _closeAllSessions() async {
    final schema = _schemaSessionId;
    _schemaSessionId = null;
    if (schema != null) await closeSession(sessionId: schema);
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

  /// 选中一条保存的连接：填字段，密码从钥匙串取。旧会话全部关掉，不拿旧连接跑新库
  Future<void> _applySaved(SavedConnection connection) async {
    _host.text = connection.host;
    _port.text = connection.port.toString();
    _user.text = connection.user;
    _database.text = connection.database ?? '';

    final password = await loadPassword(id: connection.id);
    // 钥匙串里没有就留空，让用户自己输一次 —— 不猜也不静默用旧值
    _password.text = password ?? '';

    await _resetSessions();
    if (mounted) setState(() => _savedId = connection.id);
  }

  /// 保存当前连接。id 用 user@host:port，同一个目标再存就是覆盖
  Future<void> _saveCurrent() async {
    final id = '${_user.text.trim()}@${_host.text.trim()}:${_port.text.trim()}';
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
        ),
        // 密码单独进钥匙串，配置文件里一个字符都不存
        password: _password.text.isEmpty ? null : _password.text,
      );
      if (!mounted) return;
      setState(() => _savedId = id);
      await _loadSaved();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  ConnectionConfig _readConfig() {
    final database = _database.text.trim();
    return ConnectionConfig(
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      user: _user.text.trim(),
      password: _password.text,
      database: database.isEmpty ? null : database,
    );
  }

  QueryTabState? get _activeTab => _tabs[_active].key.currentState;

  /// 点侧栏的表 → 在当前标签里浏览这张表
  Future<void> _browseTable(String table) async {
    final sql = await browseSql(table: table);
    await _activeTab?.runSql(sql);
  }

  /// 换库要重开会话：连接配置里带着 database，直接改控制器不会生效
  Future<void> _switchDatabase(String database) async {
    _database.text = database;
    await _reconnect();
  }

  /// 关掉所有会话、清掉所有标签的结果
  Future<void> _resetSessions() async {
    final schema = _schemaSessionId;
    if (mounted) setState(() => _schemaSessionId = null);
    if (schema != null) await closeSession(sessionId: schema);
    for (final entry in _tabs) {
      await entry.key.currentState?.reset();
    }
  }

  Future<void> _reconnect() async {
    await _resetSessions();
    await _activeTab?.run();
  }

  @override
  Widget build(BuildContext context) {
    final schemaSession = _schemaSessionId;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConnectionBar(
            host: _host,
            port: _port,
            user: _user,
            password: _password,
            database: _database,
            connected: schemaSession != null,
            onReconnect: _reconnect,
            saved: _saved,
            savedId: _savedId,
            onPickSaved: _applySaved,
            onSave: _saveCurrent,
          ),
          if (_error != null)
            Container(
              color: Colors.red.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: SelectableText(
                _error!,
                style: TextStyle(fontSize: 12, color: Colors.red.shade900),
              ),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (schemaSession != null)
                  TableSidebar(
                    source: RustSchemaSource(schemaSession),
                    database: _database.text.trim(),
                    onDatabaseChanged: _switchDatabase,
                    onTableSelected: _browseTable,
                    onShowStructure: (table) => showTableStructure(
                      context,
                      source: RustSchemaSource(schemaSession),
                      database: _database.text.trim(),
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
                        onSelect: (index) => setState(() => _active = index),
                        onClose: _closeTab,
                        onAdd: () => setState(_addTab),
                      ),
                      Expanded(
                        // 不在前台的标签也留着，切回来结果和编辑器内容都还在
                        child: IndexedStack(
                          index: _active,
                          children: [
                            for (final entry in _tabs)
                              QueryTab(
                                key: entry.key,
                                runner: entry.runner,
                                library: _library,
                                tokenize: (sql) => tokenizeSql(sql: sql),
                                initialSql: entry.initialSql,
                                onRan: (sql) => _retitle(entry, sql),
                                complete: _complete,
                                onConnected: _onConnected,
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
    );
  }
}

class _TabEntry {
  final int id;
  String title;
  final String initialSql;
  final GlobalKey<QueryTabState> key;
  final RustQueryRunner runner;

  _TabEntry({
    required this.id,
    required this.title,
    required this.initialSql,
    required this.key,
    required this.runner,
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
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.black12)),
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
                return InkWell(
                  key: ValueKey('tab-${entry.id}'),
                  onTap: () => onSelect(index),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 220),
                    padding: const EdgeInsets.only(left: 12, right: 2),
                    decoration: BoxDecoration(
                      color: selected ? scheme.surface : scheme.surfaceContainerHighest,
                      border: Border(
                        bottom: BorderSide(
                          color: selected ? scheme.primary : Colors.transparent,
                          width: 2,
                        ),
                        right: const BorderSide(color: Colors.black12),
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
                          tooltip: '关闭标签',
                          iconSize: 13,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => onClose(index),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(tooltip: '新标签', iconSize: 16, onPressed: onAdd, icon: const Icon(Icons.add)),
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
  final VoidCallback? onReconnect;
  final List<SavedConnection> saved;
  final String? savedId;
  final void Function(SavedConnection connection) onPickSaved;
  final VoidCallback? onSave;

  const _ConnectionBar({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.database,
    required this.connected,
    required this.onReconnect,
    required this.saved,
    required this.savedId,
    required this.onPickSaved,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          if (saved.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 150,
                child: DropdownButtonFormField<String>(
                  initialValue: savedId,
                  isDense: true,
                  isExpanded: true,
                  hint: const Text('已保存', style: TextStyle(fontSize: 11)),
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                  items: [
                    for (final connection in saved)
                      DropdownMenuItem(
                        value: connection.id,
                        child: Text(connection.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
          const SizedBox(width: 12),
          Icon(
            connected ? Icons.link : Icons.link_off,
            size: 16,
            color: connected ? Colors.green : Colors.black38,
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: onReconnect, child: const Text('重连')),
          const SizedBox(width: 6),
          Tooltip(
            message: '保存连接（密码进系统钥匙串）',
            child: OutlinedButton(onPressed: onSave, child: const Text('保存')),
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
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
      ),
    );
  }
}
