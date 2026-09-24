// 查询标签的 widget 测试：运行、快捷键、历史收藏、筛选排序怎么传给后端、高亮。
// 查询本身的行为由 cdata-core 的真库测试保证，这里用内存的 runner 和 library。

import 'package:cdata_flutter/data_source.dart';
import 'package:cdata_flutter/filter_panel.dart';
import 'package:cdata_flutter/query_tab.dart';
import 'package:cdata_flutter/sql_editor.dart';
import 'package:cdata_flutter/sql_library.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/editor.dart';
import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// 记下每次 run 的参数，返回一个 2 行的内存结果
class FakeRunner implements QueryRunner {
  final runs = <({String sql, FilterGroup filter, String? sortColumn, bool ascending})>[];
  String? error;
  bool closed = false;

  @override
  Future<QuerySummary> run(String sql, FilterGroup filter, String? sortColumn, bool sortAscending) async {
    runs.add((sql: sql, filter: filter, sortColumn: sortColumn, ascending: sortAscending));
    final message = error;
    if (message != null) throw Exception(message);
    return FakeGridSource.rows(2).summary;
  }

  @override
  GridSource gridSource(QuerySummary summary) => FakeGridSource.rows(2);

  /// 多语句脚本：runScript 返回它，childSource 按子会话 id 给各自的内容，好分辨切到了哪个结果
  ScriptSummary? script;
  final scripts = <String>[];
  final explains = <String>[];
  final childSources = <BigInt, GridSource>{};
  String? splitError;
  var droppedChildren = 0;

  /// 简化版切分：按分号切、去掉空的。真实规则（字符串、注释里的分号）在 core 测
  @override
  List<String> split(String sql) {
    final message = splitError;
    if (message != null) throw Exception(message);
    return [
      for (final part in sql.split(';'))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  @override
  Future<ScriptSummary> runScript(String sql) async {
    scripts.add(sql);
    return script!;
  }

  @override
  Future<StatementOutcome> explain(String sql) async {
    explains.add(sql);
    final message = error;
    if (message != null) throw Exception(message);
    final id = BigInt.from(99);
    childSources[id] = textGrid('plan', ['计划行']);
    return StatementOutcome(sql: 'EXPLAIN $sql', sessionId: id, summary: childSources[id]!.summary, affectedRows: BigInt.zero);
  }

  @override
  GridSource childSource(StatementOutcome outcome) => childSources[outcome.sessionId]!;

  @override
  Future<void> dropChildResults() async => droppedChildren++;

  @override
  Future<void> close() async => closed = true;
}

/// 一列文本的内存结果
FakeGridSource textGrid(String name, List<String> values) {
  return FakeGridSource(
    summary: summaryOf(columns: [column(name)], totalRows: values.length),
    rows: [
      for (final value in values) [CellValue.text(value)],
    ],
  );
}

/// 脚本里一条有结果集的语句，结果内容放进 runner 的 childSources
StatementOutcome resultOutcome(FakeRunner runner, int id, String sql, List<String> values) {
  final sessionId = BigInt.from(id);
  final grid = textGrid('v', values);
  runner.childSources[sessionId] = grid;
  return StatementOutcome(sql: sql, sessionId: sessionId, summary: grid.summary, affectedRows: BigInt.zero);
}

StatementOutcome writeOutcome(String sql, int affected) {
  return StatementOutcome(sql: sql, sessionId: null, summary: null, affectedRows: BigInt.from(affected));
}

class FakeLibrary implements SqlLibrary {
  final List<HistoryEntry> entries = [];
  final List<Favorite> saved = [];
  String? historyError;

  @override
  Future<void> addHistory(String sql) async {
    final message = historyError;
    if (message != null) throw Exception(message);
    entries.insert(0, HistoryEntry(sql: sql, executedAt: 0));
  }

  @override
  Future<List<HistoryEntry>> history() async => entries;

  @override
  Future<List<Favorite>> favorites() async => saved;

  @override
  Future<String> saveFavorite(String name, String sql) async {
    final id = 'fav-${saved.length}';
    saved.add(Favorite(id: id, name: name, sql: sql));
    return id;
  }

  @override
  Future<void> deleteFavorite(String id) async => saved.removeWhere((f) => f.id == id);
}

/// 简化版切分：只认 SELECT / FROM 和数字，足够测上色逻辑
List<SqlToken> fakeTokenize(String sql) {
  final tokens = <SqlToken>[];
  for (final match in RegExp(r'SELECT|FROM|\d+').allMatches(sql)) {
    final text = match.group(0)!;
    final kind = RegExp(r'^\d').hasMatch(text) ? SqlTokenKind.number : SqlTokenKind.keyword;
    tokens.add(SqlToken(kind: kind, start: match.start, end: match.end));
  }
  return tokens;
}

Future<GlobalKey<QueryTabState>> pumpTab(
  WidgetTester tester,
  FakeRunner runner,
  FakeLibrary library, {
  String sql = 'SELECT * FROM t',
  List<String>? ran,
}) async {
  final key = GlobalKey<QueryTabState>();
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(Brightness.light),
    home: Scaffold(
      body: QueryTab(
        key: key,
        runner: runner,
        library: library,
        tokenize: fakeTokenize,
        initialSql: sql,
        onRan: (sql) => ran?.add(sql),
        onConnected: () {},
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return key;
}

void main() {
  testWidgets('运行：跑编辑器里的 SQL，记历史，显示结果', (tester) async {
    final runner = FakeRunner();
    final library = FakeLibrary();
    final ran = <String>[];
    await pumpTab(tester, runner, library, ran: ran);

    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();

    expect(runner.runs.single.sql, 'SELECT * FROM t');
    expect(library.entries.single.sql, 'SELECT * FROM t');
    expect(ran, ['SELECT * FROM t'], reason: '标签标题跟着 SQL 变');
    expect(find.text('用户1'), findsOneWidget);
  });

  testWidgets('⌘ + Enter 运行，普通回车只是换行', (tester) async {
    final runner = FakeRunner();
    await pumpTab(tester, runner, FakeLibrary());

    await tester.tap(find.byKey(const ValueKey('sql-editor')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(runner.runs, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump(const Duration(milliseconds: 100));
    expect(runner.runs, hasLength(1));
  });

  testWidgets('排序和筛选都带着基准 SQL 传给后端，重新运行清掉', (tester) async {
    final runner = FakeRunner();
    await pumpTab(tester, runner, FakeLibrary());
    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('name'));
    await tester.pumpAndSettle();
    expect(runner.runs.last.sql, 'SELECT * FROM t', reason: '排序不改基准 SQL');
    expect(runner.runs.last.sortColumn, 'name');

    await tester.tap(find.text('name'));
    await tester.pumpAndSettle();
    expect(runner.runs.last.ascending, isFalse, reason: '同一列再点换方向');

    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();
    expect(runner.runs.last.sortColumn, isNull);
  });

  testWidgets('分组筛选原样交给后端，基准 SQL 不变；重新运行清掉', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final runner = FakeRunner();
    await pumpTab(tester, runner, FakeLibrary());
    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('filter-value-0')), '1');
    await tester.tap(find.byKey(const ValueKey('filter-add-group')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('filter-value-1.0')), '2');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    final run = runner.runs.last;
    expect(run.sql, 'SELECT * FROM t', reason: '筛选不改基准 SQL');
    expect(describeFilterGroup(run.filter), 'id = 1 且 (id = 2)');
    expect(find.text('id = 1 且 (id = 2)'), findsOneWidget, reason: '筛选条显示分组摘要');

    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();
    expect(runner.runs.last.filter.items, isEmpty);
  });

  testWidgets('查询失败显示错误，历史没记上也要说', (tester) async {
    final runner = FakeRunner()..error = "Table 't' doesn't exist";
    await pumpTab(tester, runner, FakeLibrary());
    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();
    expect(find.textContaining("doesn't exist"), findsOneWidget);

    final library = FakeLibrary()..historyError = '磁盘满了';
    await pumpTab(tester, FakeRunner(), library);
    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();
    expect(find.textContaining('记录历史失败：'), findsOneWidget);
    expect(find.text('用户1'), findsOneWidget, reason: '历史没记上不影响查询');
  });

  testWidgets('从历史里选一条放进编辑器', (tester) async {
    final library = FakeLibrary()
      ..entries.add(HistoryEntry(sql: 'SELECT 42', executedAt: DateTime(2026, 9, 24, 9, 5).millisecondsSinceEpoch));
    await pumpTab(tester, FakeRunner(), library);

    await tester.tap(find.text('历史 / 收藏'));
    await tester.pumpAndSettle();
    expect(find.text('2026-09-24 09:05'), findsOneWidget);
    await tester.tap(find.text('SELECT 42'));
    await tester.pumpAndSettle();

    final editor = tester.widget<TextField>(
      find.descendant(of: find.byKey(const ValueKey('sql-editor')), matching: find.byType(TextField)),
    );
    expect(editor.controller!.text, 'SELECT 42');
  });

  testWidgets('收藏当前 SQL、删除收藏', (tester) async {
    final library = FakeLibrary();
    await pumpTab(tester, FakeRunner(), library, sql: 'SELECT * FROM daily');

    await tester.tap(find.text('历史 / 收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('favorite-name')), '日报');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('收藏当前 SQL'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(library.saved.single.name, '日报');
    expect(library.saved.single.sql, 'SELECT * FROM daily');
    expect(find.text('日报'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('favorite-delete-fav-0')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(library.saved, isEmpty);
  });

  testWidgets('reset 关掉会话、清掉结果', (tester) async {
    final runner = FakeRunner();
    final key = await pumpTab(tester, runner, FakeLibrary());
    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();

    await key.currentState!.reset();
    await tester.pumpAndSettle();
    expect(runner.closed, isTrue);
    expect(find.text('用户1'), findsNothing);
  });

  testWidgets('高亮按 token 拆 span，token 之间的原文不丢', (tester) async {
    // 高亮按主题亮度选配色，要一个挂在 Theme 下面的真 context
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: Builder(builder: (built) {
        context = built;
        return const SizedBox();
      }),
    ));
    final controller = SqlEditingController(tokenize: fakeTokenize, text: 'SELECT 1 FROM t');
    addTearDown(controller.dispose);
    final span = controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 13),
      withComposing: true,
    );
    final children = span.children!.cast<TextSpan>();
    final texts = [for (final child in children) child.text];
    expect(texts, ['SELECT', ' ', '1', ' ', 'FROM', ' t']);
    expect(children[0].style!.fontWeight, FontWeight.w600, reason: '关键字加粗');
    expect(span.toPlainText(), 'SELECT 1 FROM t');
  });

  test('输入法组词时不高亮，保住组词区', () {
    final controller = SqlEditingController(tokenize: fakeTokenize, text: 'SELECT 中文');
    controller.value = controller.value.copyWith(composing: const TextRange(start: 7, end: 9));
    final span = controller.buildTextSpan(context: _FakeContext(), withComposing: true);
    // 默认实现会把组词区单独拆出来画下划线
    expect(span.toPlainText(), 'SELECT 中文');
    final styles = [for (final child in span.children!.cast<TextSpan>()) child.style];
    expect(styles.any((style) => style?.decoration == TextDecoration.underline), isTrue);
  });

  testWidgets('多条语句：每个结果集一个标签，写语句汇总成影响行数', (tester) async {
    final runner = FakeRunner();
    runner.script = ScriptSummary(
      outcomes: [
        resultOutcome(runner, 11, 'SELECT a', ['甲']),
        writeOutcome('UPDATE t SET v = 1', 2),
        resultOutcome(runner, 12, 'SELECT b', ['乙']),
      ],
      failure: null,
    );
    await pumpTab(tester, runner, FakeLibrary(), sql: 'SELECT a; UPDATE t SET v = 1; SELECT b');

    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();

    expect(runner.runs, isEmpty, reason: '多条语句不走单条路径');
    expect(runner.scripts.single, 'SELECT a; UPDATE t SET v = 1; SELECT b');
    expect(runner.droppedChildren, 1, reason: '新一轮运行先清掉上一轮的子结果');
    expect(find.textContaining('执行了 3 条语句，其中 1 条没有结果集，共影响 2 行'), findsOneWidget);
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsNothing, reason: '第二个结果在后台标签里');

    await tester.tap(find.byKey(const ValueKey('result-tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('乙'), findsOneWidget);
    expect(find.text('甲'), findsNothing);
  });

  testWidgets('脚本中途失败：说清第几条、前面的已经执行', (tester) async {
    final runner = FakeRunner();
    runner.script = ScriptSummary(
      outcomes: [writeOutcome('INSERT INTO t VALUES (1)', 1)],
      failure: StatementFailure(index: 1, sql: 'SELECT * FROM nope', message: "Table 'nope' doesn't exist"),
    );
    await pumpTab(tester, runner, FakeLibrary(), sql: 'INSERT INTO t VALUES (1); SELECT * FROM nope; SELECT 3');

    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();

    expect(find.textContaining('第 2 条语句失败，后面的没有执行；前面 1 条已经执行'), findsOneWidget);
    expect(find.textContaining("Table 'nope' doesn't exist"), findsOneWidget);
    expect(find.textContaining('执行了 1 条语句'), findsOneWidget, reason: '失败时也要看到失败前执行了几条');
    expect(find.text('这段 SQL 没有返回结果集'), findsOneWidget);
  });

  testWidgets('切分被拒绝（比如 DELIMITER）：显示原因，什么都不跑', (tester) async {
    final runner = FakeRunner()..splitError = 'DELIMITER 是命令行客户端的指令';
    final library = FakeLibrary();
    await pumpTab(tester, runner, library, sql: 'DELIMITER //');

    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();

    expect(find.textContaining('DELIMITER 是命令行客户端的指令'), findsOneWidget);
    expect(runner.runs, isEmpty);
    expect(runner.scripts, isEmpty);
    expect(library.entries, isEmpty, reason: '没跑的语句不记历史');
  });

  testWidgets('执行计划：单独一个标签，筛选条只跟着单条结果', (tester) async {
    final runner = FakeRunner();
    await pumpTab(tester, runner, FakeLibrary());

    await tester.tap(find.text('运行'));
    await tester.pumpAndSettle();
    expect(find.text('筛选'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '执行计划'));
    await tester.pumpAndSettle();

    expect(runner.explains.single, 'SELECT * FROM t');
    expect(find.text('计划行'), findsOneWidget, reason: '看完计划直接切到计划标签');
    expect(find.text('筛选'), findsNothing, reason: '筛选作用在单条结果上，看计划时不显示');

    await tester.tap(find.byKey(const ValueKey('result-tab-0')));
    await tester.pumpAndSettle();
    expect(find.text('用户1'), findsOneWidget);
    expect(find.text('筛选'), findsOneWidget);

    // 再看一次是替换，不会堆出两个计划标签
    await tester.tap(find.widgetWithText(OutlinedButton, '执行计划'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('result-tab-2')), findsNothing);
  });
}

/// 组词时走默认实现，用不到主题，这里给一个空壳 context
class _FakeContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
