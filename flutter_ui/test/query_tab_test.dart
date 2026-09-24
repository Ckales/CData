// 查询标签的 widget 测试：运行、快捷键、历史收藏、筛选排序怎么传给后端、高亮。
// 查询本身的行为由 cdata-core 的真库测试保证，这里用内存的 runner 和 library。

import 'package:cdata_flutter/data_source.dart';
import 'package:cdata_flutter/query_tab.dart';
import 'package:cdata_flutter/sql_editor.dart';
import 'package:cdata_flutter/sql_library.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// 记下每次 run 的参数，返回一个 2 行的内存结果
class FakeRunner implements QueryRunner {
  final runs = <({String sql, List<FilterCondition> conditions, String? sortColumn, bool ascending})>[];
  String? error;
  bool closed = false;

  @override
  Future<QuerySummary> run(
    String sql,
    List<FilterCondition> conditions,
    bool matchAll,
    String? sortColumn,
    bool sortAscending,
  ) async {
    runs.add((sql: sql, conditions: conditions, sortColumn: sortColumn, ascending: sortAscending));
    final message = error;
    if (message != null) throw Exception(message);
    return FakeGridSource.rows(2).summary;
  }

  @override
  GridSource gridSource(QuerySummary summary) => FakeGridSource.rows(2);

  @override
  Future<void> close() async => closed = true;
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
}

/// 组词时走默认实现，用不到主题，这里给一个空壳 context
class _FakeContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
