import 'package:flutter/material.dart';

import 'data_source.dart';
import 'filter_panel.dart';
import 'result_grid.dart';
import 'src/rust/api/connections.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/schema.dart';
import 'table_sidebar.dart';

/// 连接 + 查询 + 结果。最小链路的界面载体，还不是最终形态的主窗口。
class QueryPage extends StatefulWidget {
  const QueryPage({super.key});

  @override
  State<QueryPage> createState() => _QueryPageState();
}

class _QueryPageState extends State<QueryPage> {
  /// 上限。超过就截断并在界面上显著提示，不静默丢行
  static const int _maxRows = 100000;

  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '3306');
  final _user = TextEditingController(text: 'root');
  // 密码不预填 —— 凭据不进源码
  final _password = TextEditingController();
  final _database = TextEditingController();
  final _sql = TextEditingController(text: 'SELECT * FROM big_rows ORDER BY id');

  BigInt? _sessionId;
  QuerySummary? _summary;
  String? _error;
  bool _busy = false;
  Duration? _elapsed;

  /// 筛选、排序的基准 SQL。每次都从它包一层，
  /// 不然在已排序的结果上再包，点几次就套成俄罗斯套娃
  String _baseSql = '';
  String? _sortColumn;
  bool _sortAscending = true;
  List<FilterCondition> _filters = const [];
  bool _matchAll = true;

  /// 基准 SQL 最近一次成功返回的列名。筛选出错时 _summary 是 null，
  /// 靠它继续显示筛选条，才能把写错的条件改掉或清掉
  List<String> _columns = const [];

  List<SavedConnection> _saved = [];
  String? _savedId;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    try {
      final saved = await listConnections();
      if (mounted) setState(() => _saved = saved);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 选中一条保存的连接：填字段，密码从钥匙串取
  Future<void> _applySaved(SavedConnection connection) async {
    _host.text = connection.host;
    _port.text = connection.port.toString();
    _user.text = connection.user;
    _database.text = connection.database ?? '';

    final password = await loadPassword(id: connection.id);
    // 钥匙串里没有就留空，让用户自己输一次 —— 不猜也不静默用旧值
    _password.text = password ?? '';

    if (!mounted) return;
    setState(() {
      _savedId = connection.id;
      _sessionId = null;
      _summary = null;
    });
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

  @override
  void dispose() {
    final id = _sessionId;
    if (id != null) {
      closeSession(sessionId: id);
    }
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _database.dispose();
    _sql.dispose();
    super.dispose();
  }

  /// 跑编辑框里的新 SQL，筛选和排序都清掉
  Future<void> _run() async {
    _baseSql = _sql.text;
    setState(() {
      _sortColumn = null;
      _sortAscending = true;
      _filters = const [];
      _matchAll = true;
      _columns = const [];
    });
    await _runView();
  }

  /// 点列头排序。同一列再点一次换方向，换列则从升序开始
  Future<void> _sortBy(String column) async {
    if (_busy || _baseSql.isEmpty) return;

    final ascending = _sortColumn == column ? !_sortAscending : true;
    setState(() {
      _sortColumn = column;
      _sortAscending = ascending;
    });
    await _runView();
  }

  Future<void> _editFilter() async {
    final result = await showFilterDialog(
      context,
      columns: _columns,
      initial: _filters,
      matchAll: _matchAll,
    );
    if (result == null || !mounted) return;

    setState(() {
      _filters = result.conditions;
      _matchAll = result.matchAll;
    });
    await _runView();
  }

  Future<void> _clearFilter() async {
    setState(() => _filters = const []);
    await _runView();
  }

  /// 按当前的基准 SQL + 筛选 + 排序跑一次。SQL 在 core 里生成
  Future<void> _runView() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final started = DateTime.now();
    try {
      // 换了连接参数就重开会话，避免拿旧连接跑新库
      final id = _sessionId ?? await openSession(config: _readConfig());

      final summary = await executeView(
        sessionId: id,
        sql: _baseSql,
        conditions: _filters,
        matchAll: _matchAll,
        sortColumn: _sortColumn,
        sortAscending: _sortAscending,
        maxRows: BigInt.from(_maxRows),
      );

      if (!mounted) return;
      setState(() {
        _sessionId = id;
        _summary = summary;
        _columns = [for (final column in summary.columns) column.name];
        _elapsed = DateTime.now().difference(started);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _summary = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
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

  /// 点侧栏的表 → 换成浏览这张表的 SQL 并跑一次
  Future<void> _browseTable(String table) async {
    _sql.text = await browseSql(table: table);
    await _run();
  }

  /// 换库要重开会话：连接配置里带着 database，直接改控制器不会生效
  Future<void> _switchDatabase(String database) async {
    _database.text = database;
    await _reconnect();
  }

  Future<void> _reconnect() async {
    final id = _sessionId;
    if (id != null) {
      await closeSession(sessionId: id);
    }
    if (!mounted) return;
    setState(() {
      _sessionId = null;
      _summary = null;
    });
    await _run();
  }

  @override
  Widget build(BuildContext context) {
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
            connected: _sessionId != null,
            onReconnect: _busy ? null : _reconnect,
            saved: _saved,
            savedId: _savedId,
            onPickSaved: _applySaved,
            onSave: _busy ? null : _saveCurrent,
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_sessionId != null)
                  TableSidebar(
                    source: RustSchemaSource(_sessionId!),
                    database: _database.text.trim(),
                    onDatabaseChanged: _switchDatabase,
                    onTableSelected: _browseTable,
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SqlBar(controller: _sql, busy: _busy, onRun: _busy ? null : _run),
                      if (_columns.isNotEmpty)
                        FilterBar(
                          conditions: _filters,
                          matchAll: _matchAll,
                          onEdit: _busy ? null : _editFilter,
                          onClear: _busy ? null : _clearFilter,
                        ),
                      if (_error != null) _ErrorBanner(message: _error!),
                      if (_elapsed != null && _error == null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          child: Text(
                            '耗时 ${_elapsed!.inMilliseconds} ms',
                            style: const TextStyle(fontSize: 11, color: Colors.black54),
                          ),
                        ),
                      Expanded(
                        child: _summary == null
                            ? const Center(child: Text('填好连接信息，运行一条查询'))
                            : ResultGrid(
                                source: RustGridSource(
                                  sessionId: _sessionId!,
                                  summary: _summary!,
                                ),
                                onSortColumn: _sortBy,
                                sortColumn: _sortColumn,
                                sortAscending: _sortAscending,
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

class _SqlBar extends StatelessWidget {
  final TextEditingController controller;
  final bool busy;
  final VoidCallback? onRun;

  const _SqlBar({required this.controller, required this.busy, required this.onRun});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              maxLines: 3,
              minLines: 2,
              style: const TextStyle(fontSize: 13, fontFamily: 'Menlo'),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.all(10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: onRun,
            // 无限动画会卡死 pumpAndSettle，用文字表达忙碌状态
            child: Text(busy ? '运行中…' : '运行'),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;

  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.red.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      // 限高可滚动：错误信息可能很长，不能把界面撑爆
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 120),
        child: SingleChildScrollView(
          child: SelectableText(
            message,
            style: TextStyle(color: Colors.red.shade900, fontSize: 12, fontFamily: 'Menlo'),
          ),
        ),
      ),
    );
  }
}
