import 'package:flutter/material.dart';

import 'data_source.dart';
import 'filter_panel.dart';
import 'result_grid.dart';
import 'sql_editor.dart';
import 'sql_library.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/editor.dart';
// 和下面 QueryRunner 的同名方法重名，方法体里直接调会解析成方法自己
import 'src/rust/api/editor.dart' as editor show explain, dropChildResults;
import 'src/rust/api/options.dart';

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

  /// 编辑器里的语句，由 core 按分号切。拿不准（DELIMITER、存储过程体）就抛错
  List<String> split(String sql);

  /// 多条语句按顺序在同一条连接上跑，每个结果集放在一个子会话里
  Future<ScriptSummary> runScript(String sql);

  /// 执行计划。结果同样放在子会话里
  Future<StatementOutcome> explain(String sql);

  /// 子结果的网格数据源，和 gridSource 一样每个结果只建一次
  GridSource childSource(StatementOutcome outcome);

  /// 新一轮运行前关掉上一轮的子结果
  Future<void> dropChildResults();

  /// 关掉会话。之后再 run 会开一个新的
  Future<void> close();
}

class RustQueryRunner implements QueryRunner {
  /// 连接参数由页面上的连接栏提供，开会话时才读，改了参数要先 close
  final ConnectionConfig Function() readConfig;

  /// 行数上限，来自偏好设置。超过就截断并在界面上显著提示，不静默丢行
  final BigInt Function() maxRows;

  /// SSH 主机没见过时问用户要不要信任
  final Future<bool> Function(HostKeyIssue issue) confirmHostKey;
  BigInt? _sessionId;

  RustQueryRunner({
    required this.readConfig,
    required this.maxRows,
    required this.confirmHostKey,
  });

  @override
  Future<QuerySummary> run(
    String sql,
    List<FilterCondition> conditions,
    bool matchAll,
    String? sortColumn,
    bool sortAscending,
  ) async {
    final id = _sessionId ??= await _open();
    return executeView(
      sessionId: id,
      sql: sql,
      conditions: conditions,
      matchAll: matchAll,
      sortColumn: sortColumn,
      sortAscending: sortAscending,
      maxRows: maxRows(),
    );
  }

  /// 开会话只建连接和隧道、不跑语句，所以信任主机后重来一次是安全的
  Future<BigInt> _open() async {
    final config = readConfig();
    try {
      return await openSession(config: config);
    } on OpenSessionError catch (e) {
      final issue = e.hostKey;
      // 只有「没见过」能由用户确认；指纹和记录的不一样可能是中间人，一律拒绝
      if (issue == null || issue.kind != HostKeyIssueKind.unknown) rethrow;
      if (!await confirmHostKey(issue)) rethrow;
      await trustHostKey(
        host: issue.host,
        port: issue.port,
        fingerprint: issue.fingerprint,
      );
      return openSession(config: config);
    }
  }

  @override
  GridSource gridSource(QuerySummary summary) {
    return RustGridSource(sessionId: _sessionId!, summary: summary);
  }

  @override
  List<String> split(String sql) => splitStatements(sql: sql);

  @override
  Future<ScriptSummary> runScript(String sql) async {
    final id = _sessionId ??= await _open();
    return executeScript(sessionId: id, sql: sql, maxRows: maxRows());
  }

  @override
  Future<StatementOutcome> explain(String sql) async {
    final id = _sessionId ??= await _open();
    return editor.explain(sessionId: id, sql: sql, maxRows: maxRows());
  }

  @override
  GridSource childSource(StatementOutcome outcome) {
    return RustGridSource(sessionId: outcome.sessionId!, summary: outcome.summary!);
  }

  @override
  Future<void> dropChildResults() async {
    final id = _sessionId;
    if (id != null) await editor.dropChildResults(sessionId: id);
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

  final double editorFontSize;

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
    this.editorFontSize = 13,
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

  /// 多语句脚本的结果集和执行计划，每个一个结果标签。单条语句的结果还是 _source，筛选排序只对它
  List<_ExtraResult> _extras = const [];

  /// 在看第几个结果，下标对着 _views
  int _activeResult = 0;

  /// 脚本跑完的概况，比如执行了几条、影响了多少行
  String? _scriptNotice;

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

  /// 跑编辑器里的 SQL，筛选和排序都清掉。一条语句走能筛选排序的单条路径，多条走脚本
  Future<void> run() async {
    if (_busy) return;
    _baseSql = _sql.text;

    final List<String> statements;
    try {
      statements = widget.runner.split(_baseSql);
    } catch (e) {
      setState(() => _error = '$e');
      return;
    }

    setState(() {
      _sortColumn = null;
      _sortAscending = true;
      _filters = const [];
      _matchAll = true;
      _columns = const [];
      _extras = const [];
      _activeResult = 0;
      _scriptNotice = null;
    });
    widget.onRan(_baseSql);

    String? historyError;
    try {
      await widget.library.addHistory(_baseSql);
    } catch (e) {
      historyError = '记录历史失败：$e';
    }

    try {
      await widget.runner.dropChildResults();
    } catch (e) {
      if (mounted) setState(() => _error = '清理上一轮的结果失败：$e');
      return;
    }

    if (statements.length > 1) {
      await _runScript();
    } else {
      await _runView();
    }
    // 历史没记上不影响查询，但要让人知道
    if (mounted && historyError != null && _error == null) setState(() => _error = historyError);
  }

  Future<void> _runScript() async {
    setState(() {
      _busy = true;
      _error = null;
      _source = null;
    });

    final started = DateTime.now();
    try {
      final summary = await widget.runner.runScript(_baseSql);
      if (!mounted) return;

      final extras = <_ExtraResult>[];
      var withoutResult = 0;
      var affected = BigInt.zero;
      for (final outcome in summary.outcomes) {
        if (outcome.sessionId == null) {
          withoutResult++;
          affected += outcome.affectedRows;
          continue;
        }
        extras.add(
          _ExtraResult(
            title: '结果 ${extras.length + 1}',
            sql: outcome.sql,
            source: widget.runner.childSource(outcome),
            isPlan: false,
          ),
        );
      }

      var notice = '执行了 ${summary.outcomes.length} 条语句';
      if (withoutResult > 0) notice += '，其中 $withoutResult 条没有结果集，共影响 $affected 行';

      final failure = summary.failure;
      setState(() {
        _extras = extras;
        _activeResult = 0;
        _scriptNotice = notice;
        _elapsed = DateTime.now().difference(started);
        if (failure != null) _error = _describeFailure(failure);
      });
      widget.onConnected();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 失败之前的语句已经生效：DDL 隐式提交，自动提交下的写入也撤不回来，要说清楚
  String _describeFailure(StatementFailure failure) {
    final number = failure.index + 1;
    final head = failure.index == 0
        ? '第 1 条语句失败，后面的没有执行。'
        : '第 $number 条语句失败，后面的没有执行；前面 ${failure.index} 条已经执行，写入和 DDL 撤不回来。';
    return '$head\n${failure.sql}\n${failure.message}';
  }

  /// 看当前语句的执行计划，放在一个结果标签里。同时只留一份，再看就替换
  Future<void> _explain() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await widget.runner.explain(_sql.text);
      if (!mounted) return;
      final plan = _ExtraResult(
        title: '执行计划',
        sql: outcome.sql,
        source: widget.runner.childSource(outcome),
        isPlan: true,
      );
      setState(() {
        _extras = [
          for (final extra in _extras)
            if (!extra.isPlan) extra,
          plan,
        ];
        _activeResult = _views.length - 1;
      });
      widget.onConnected();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 结果标签：单条语句的结果（有的话）在最前，后面是脚本结果和执行计划
  List<_ResultView> get _views {
    final source = _source;
    return [
      if (source != null) _ResultView(title: '结果', sql: _baseSql, source: source, isMain: true),
      for (final extra in _extras) _ResultView(title: extra.title, sql: extra.sql, source: extra.source, isMain: false),
    ];
  }

  /// 连接参数变了：关掉会话、清掉结果。下次 run 会按新参数重开
  Future<void> reset() async {
    await widget.runner.close();
    if (!mounted) return;
    setState(() {
      _source = null;
      _error = null;
      _elapsed = null;
      _extras = const [];
      _activeResult = 0;
      _scriptNotice = null;
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
    final views = _views;
    final active = views.isEmpty ? 0 : _activeResult.clamp(0, views.length - 1);
    final showingMain = views.isNotEmpty && views[active].isMain;
    final notice = _scriptNotice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SqlBar(
          controller: _sql,
          complete: widget.complete,
          busy: _busy,
          onRun: _busy ? null : run,
          onOpenLibrary: _openLibrary,
          onExplain: _busy ? null : _explain,
          fontSize: widget.editorFontSize,
        ),
        // 筛选只作用在单条语句的结果上，看脚本结果和执行计划时不显示
        if (_columns.isNotEmpty && (views.isEmpty || showingMain))
          FilterBar(
            conditions: _filters,
            matchAll: _matchAll,
            onEdit: _busy ? null : _editFilter,
            onClear: _busy ? null : _clearFilter,
          ),
        if (_error != null) _ErrorBanner(message: _error!),
        // 脚本失败时也要显示概况：失败之前执行了几条，和错误信息一起看
        if (_elapsed != null && (_error == null || notice != null))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              notice == null ? '耗时 ${_elapsed!.inMilliseconds} ms' : '耗时 ${_elapsed!.inMilliseconds} ms · $notice',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (views.length > 1)
          _ResultStrip(
            views: views,
            active: active,
            onSelect: (index) => setState(() => _activeResult = index),
          ),
        Expanded(
          child: views.isEmpty
              ? Center(child: Text(notice == null ? '填好连接信息，运行一条查询' : '这段 SQL 没有返回结果集'))
              // 不在前台的结果也留着，切回来滚动位置和选区都还在
              : IndexedStack(
                  index: active,
                  children: [
                    for (final view in views)
                      ResultGrid(
                        key: ObjectKey(view.source),
                        source: view.source,
                        // 脚本结果和执行计划不能按列重跑：单独重跑一条语句可能拿不到它依赖的会话状态
                        onSortColumn: view.isMain ? _sortBy : null,
                        sortColumn: view.isMain ? _sortColumn : null,
                        sortAscending: _sortAscending,
                        pickSavePath: widget.pickSavePath,
                      ),
                  ],
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
  final VoidCallback? onExplain;
  final double fontSize;

  const _SqlBar({
    required this.controller,
    required this.complete,
    required this.busy,
    required this.onRun,
    required this.onOpenLibrary,
    required this.onExplain,
    required this.fontSize,
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
              fontSize: fontSize,
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
                OutlinedButton(
                  onPressed: onOpenLibrary,
                  child: const Text('历史 / 收藏'),
                ),
                const SizedBox(height: 4),
                Tooltip(
                  message: 'EXPLAIN：只看计划，不执行语句',
                  child: OutlinedButton(onPressed: onExplain, child: const Text('执行计划')),
                ),
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      // 限高可滚动：错误信息可能很长，不能把界面撑爆
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 120),
        child: SingleChildScrollView(
          child: SelectableText(
            message,
            style: TextStyle(
              color: scheme.onErrorContainer,
              fontSize: 12,
              fontFamily: 'Menlo',
            ),
          ),
        ),
      ),
    );
  }
}

class _ExtraResult {
  final String title;
  final String sql;
  final GridSource source;
  final bool isPlan;

  const _ExtraResult({required this.title, required this.sql, required this.source, required this.isPlan});
}

class _ResultView {
  final String title;
  final String sql;
  final GridSource source;

  /// 单条语句的结果，能筛选排序
  final bool isMain;

  const _ResultView({required this.title, required this.sql, required this.source, required this.isMain});
}

class _ResultStrip extends StatelessWidget {
  final List<_ResultView> views;
  final int active;
  final void Function(int index) onSelect;

  const _ResultStrip({required this.views, required this.active, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: views.length,
        itemBuilder: (context, index) {
          final view = views[index];
          final selected = index == active;
          return Tooltip(
            message: view.sql,
            waitDuration: const Duration(milliseconds: 600),
            child: InkWell(
              key: ValueKey('result-tab-$index'),
              onTap: () => onSelect(index),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 2),
                  ),
                ),
                child: Text(
                  view.title,
                  style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w600 : null),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
