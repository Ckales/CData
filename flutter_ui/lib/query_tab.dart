import 'package:flutter/material.dart';

import 'data_source.dart';
import 'filter_panel.dart';
import 'result_grid.dart';
import 'sql_editor.dart';
import 'sql_library.dart';
import 'src/rust/api/db.dart';

/// 一个标签页跑查询的后端。每个标签一个会话：结果集留在会话里，一个会话只放一份结果
abstract class QueryRunner {
  Future<QuerySummary> run(
    String sql,
    List<FilterCondition> conditions,
    bool matchAll,
    String? sortColumn,
    bool sortAscending,
  );

  /// 这次结果的网格数据源。每次查询完成只建一次 —— 每次重绘都新建的话，
  /// 网格会以为换了结果集，把窗口、选区全部重置
  GridSource gridSource(QuerySummary summary);

  /// 关掉会话。之后再 run 会开一个新的
  Future<void> close();
}

class RustQueryRunner implements QueryRunner {
  /// 上限。超过就截断并在界面上显著提示，不静默丢行
  static const int maxRows = 100000;

  /// 连接参数由页面上的连接栏提供，开会话时才读，改了参数要先 close
  final ConnectionConfig Function() readConfig;
  BigInt? _sessionId;

  RustQueryRunner({required this.readConfig});

  @override
  Future<QuerySummary> run(
    String sql,
    List<FilterCondition> conditions,
    bool matchAll,
    String? sortColumn,
    bool sortAscending,
  ) async {
    final id = _sessionId ??= await openSession(config: readConfig());
    return executeView(
      sessionId: id,
      sql: sql,
      conditions: conditions,
      matchAll: matchAll,
      sortColumn: sortColumn,
      sortAscending: sortAscending,
      maxRows: BigInt.from(maxRows),
    );
  }

  @override
  GridSource gridSource(QuerySummary summary) {
    return RustGridSource(sessionId: _sessionId!, summary: summary);
  }

  @override
  Future<void> close() async {
    final id = _sessionId;
    _sessionId = null;
    if (id != null) await closeSession(sessionId: id);
  }
}

/// 一个查询标签：SQL 编辑器 + 筛选 + 结果
class QueryTab extends StatefulWidget {
  final QueryRunner runner;
  final SqlLibrary library;
  final SqlTokenizer tokenize;

  /// 编辑器补全，null 表示不补全
  final SqlCompleter? complete;
  final String initialSql;

  /// 跑了新 SQL，标签标题跟着变
  final void Function(String sql) onRan;

  /// 查询成功过一次，页面据此打开侧栏
  final VoidCallback onConnected;

  /// 导出时选保存位置，null 用网格的默认实现（系统对话框）
  final Future<String?> Function(String suggestedName)? pickSavePath;

  const QueryTab({
    super.key,
    required this.runner,
    required this.library,
    required this.tokenize,
    this.complete,
    required this.onRan,
    required this.onConnected,
    this.initialSql = '',
    this.pickSavePath,
  });

  @override
  State<QueryTab> createState() => QueryTabState();
}

class QueryTabState extends State<QueryTab> {
  late final SqlEditingController _sql = SqlEditingController(
    tokenize: widget.tokenize,
    text: widget.initialSql,
  );

  GridSource? _source;
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

  /// 基准 SQL 最近一次成功返回的列名。筛选出错时 _source 是 null，
  /// 靠它继续显示筛选条，才能把写错的条件改掉或清掉
  List<String> _columns = const [];

  @override
  void dispose() {
    _sql.dispose();
    super.dispose();
  }

  /// 把 SQL 放进编辑器并跑。侧栏点表、历史里选一条都走这里
  Future<void> runSql(String sql) async {
    _sql.text = sql;
    await run();
  }

  /// 跑编辑器里的 SQL，筛选和排序都清掉
  Future<void> run() async {
    if (_busy) return;
    _baseSql = _sql.text;
    setState(() {
      _sortColumn = null;
      _sortAscending = true;
      _filters = const [];
      _matchAll = true;
      _columns = const [];
    });
    widget.onRan(_baseSql);

    String? historyError;
    try {
      await widget.library.addHistory(_baseSql);
    } catch (e) {
      historyError = '记录历史失败：$e';
    }

    await _runView();
    // 历史没记上不影响查询，但要让人知道
    if (mounted && historyError != null && _error == null) setState(() => _error = historyError);
  }

  /// 连接参数变了：关掉会话、清掉结果。下次 run 会按新参数重开
  Future<void> reset() async {
    await widget.runner.close();
    if (!mounted) return;
    setState(() {
      _source = null;
      _error = null;
      _elapsed = null;
    });
  }

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

  Future<void> _openLibrary() async {
    final sql = await showSqlLibrary(context, library: widget.library, currentSql: _sql.text);
    if (sql != null && mounted) _sql.text = sql;
  }

  /// 按当前的基准 SQL + 筛选 + 排序跑一次。SQL 在 core 里生成
  Future<void> _runView() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final started = DateTime.now();
    try {
      final summary = await widget.runner.run(
        _baseSql,
        _filters,
        _matchAll,
        _sortColumn,
        _sortAscending,
      );
      if (!mounted) return;
      setState(() {
        _source = widget.runner.gridSource(summary);
        _columns = [for (final column in summary.columns) column.name];
        _elapsed = DateTime.now().difference(started);
      });
      widget.onConnected();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _source = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SqlBar(
          controller: _sql,
          complete: widget.complete,
          busy: _busy,
          onRun: _busy ? null : run,
          onOpenLibrary: _openLibrary,
        ),
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
          child: source == null
              ? const Center(child: Text('填好连接信息，运行一条查询'))
              : ResultGrid(
                  source: source,
                  onSortColumn: _sortBy,
                  sortColumn: _sortColumn,
                  sortAscending: _sortAscending,
                  pickSavePath: widget.pickSavePath,
                ),
        ),
      ],
    );
  }
}

class _SqlBar extends StatelessWidget {
  final SqlEditingController controller;
  final SqlCompleter? complete;
  final bool busy;
  final VoidCallback? onRun;
  final VoidCallback onOpenLibrary;

  const _SqlBar({
    required this.controller,
    required this.complete,
    required this.busy,
    required this.onRun,
    required this.onOpenLibrary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SqlEditorField(
              key: const ValueKey('sql-editor'),
              controller: controller,
              complete: complete,
              onRun: onRun,
            ),
          ),
          const SizedBox(width: 8),
          // stretch 的按钮列放在 Row 里必须给定宽度，否则拿到的是无限宽
          SizedBox(
            width: 140,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Tooltip(
                  message: '⌘ / Ctrl + Enter',
                  child: FilledButton(
                    onPressed: onRun,
                    // 无限动画会卡死 pumpAndSettle，用文字表达忙碌状态
                    child: Text(busy ? '运行中…' : '运行'),
                  ),
                ),
                const SizedBox(height: 4),
                OutlinedButton(onPressed: onOpenLibrary, child: const Text('历史 / 收藏')),
              ],
            ),
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
