// 结果网格的 widget 测试。喂内存数据，不起 app、不连库。
//
// 真库行为（SQL 生成、拒绝规则、类型保真）由 cdata-core 的 Rust 测试保证，
// 这里只管界面这一层：渲染对不对、点了有没有反应、该拒绝的有没有说明原因。

import 'package:cdata_flutter/result_grid.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<void> pumpGrid(
  WidgetTester tester,
  FakeGridSource source, {
  void Function(String column)? onSortColumn,
  String? sortColumn,
  bool sortAscending = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ResultGrid(
          source: source,
          onSortColumn: onSortColumn,
          sortColumn: sortColumn,
          sortAscending: sortAscending,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 双击。两次 tap 之间要留一点时间，否则被当成单击
Future<void> doubleTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  // 编辑态里 TextField 的光标是无限动画，不能 pumpAndSettle
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('渲染列头、行号和数据', (tester) async {
    await pumpGrid(tester, FakeGridSource.rows(3));

    expect(find.text('id'), findsOneWidget);
    expect(find.text('name'), findsOneWidget);
    expect(find.text('用户1'), findsOneWidget);
    expect(find.text('用户3'), findsOneWidget);
    expect(find.text('3 行'), findsOneWidget);
  });

  testWidgets('滚动到窗口外会取下一段', (tester) async {
    final source = FakeGridSource.rows(5000);
    await pumpGrid(tester, source);

    expect(find.text('用户1'), findsOneWidget);

    // 一行 30px，拖 12000px 约 400 行
    await tester.drag(find.byType(ListView), const Offset(0, -12000));
    await tester.pumpAndSettle();

    expect(find.text('用户1'), findsNothing);
    expect(find.textContaining('用户4'), findsWidgets);
  });

  testWidgets('截断时显著提示，不静默丢数据', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(
        columns: [column('id'), column('name')],
        totalRows: 2,
        truncated: true,
      ),
      rows: [
        [CellValue.int(1), CellValue.text('a')],
        [CellValue.int(2), CellValue.text('b')],
      ],
    );
    await pumpGrid(tester, source);

    expect(find.textContaining('已截断'), findsOneWidget);
  });

  testWidgets('NULL 和二进制有可辨认的占位，不显示成空白', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(columns: [column('id'), column('data')], totalRows: 1),
      rows: [
        [CellValue.null_(), CellValue.bytes(bytesOf(12))],
      ],
    );
    await pumpGrid(tester, source);

    expect(find.text('NULL'), findsOneWidget);
    expect(find.text('<二进制 12 字节>'), findsOneWidget);
  });

  testWidgets('双击改值会写回并显示新值', (tester) async {
    final source = FakeGridSource.rows(2);
    await pumpGrid(tester, source);

    await doubleTap(tester, find.text('用户1'));
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '改过了');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(source.edits, hasLength(1));
    expect(source.edits.first.$1, 0, reason: '改的是第 0 行');
    expect(source.edits.first.$2, 1, reason: '改的是第 1 列');
    expect(find.text('改过了'), findsOneWidget);
  });

  testWidgets('∅ 写入 NULL，和空字符串区分开', (tester) async {
    final source = FakeGridSource.rows(2);
    await pumpGrid(tester, source);

    await doubleTap(tester, find.text('用户1'));
    await tester.tap(find.text('∅'));
    await tester.pumpAndSettle();

    expect(source.edits.first.$3, const CellValue.null_());
    expect(find.text('NULL'), findsOneWidget);

    // 再确认空字符串走的是另一条路，不会被当成 NULL
    await doubleTap(tester, find.text('用户2'));
    await tester.enterText(find.byType(TextField), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(source.edits.last.$3, const CellValue.text(''));
  });

  testWidgets('主键列拒绝编辑并说明原因', (tester) async {
    final source = FakeGridSource.rows(2);
    await pumpGrid(tester, source);

    // 第 0 行第 0 列是主键。用 key 定位，行号列也显示 1
    await doubleTap(tester, find.byKey(const ValueKey('cell-0-0')));

    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('主键'), findsOneWidget);
    expect(source.edits, isEmpty);
  });

  testWidgets('只读结果集在状态栏说明原因', (tester) async {
    final source = FakeGridSource.rows(
      2,
      editability: const Editability.readOnly('表 no_pk 没有主键，无法安全定位行，不能编辑'),
    );
    await pumpGrid(tester, source);

    expect(find.textContaining('没有主键'), findsOneWidget);

    await doubleTap(tester, find.text('用户1'));
    expect(find.byType(TextField), findsNothing);
    expect(source.edits, isEmpty);
  });

  testWidgets('二进制单元格拒绝编辑', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(columns: [column('id'), column('data')], totalRows: 1),
      rows: [
        [CellValue.int(1), CellValue.bytes(bytesOf(4))],
      ],
    );
    await pumpGrid(tester, source);

    await doubleTap(tester, find.byKey(const ValueKey('cell-0-1')));

    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('二进制'), findsWidgets);
    expect(source.edits, isEmpty);
  });

  testWidgets('写回失败要把错误显示出来，不能静默', (tester) async {
    final source = FakeGridSource.rows(2)..editError = '预期影响 1 行，实际 0 行';
    await pumpGrid(tester, source);

    await doubleTap(tester, find.text('用户1'));
    await tester.enterText(find.byType(TextField), 'x');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining('实际 0 行'), findsOneWidget);
  });

  testWidgets('点列头触发排序回调并画箭头', (tester) async {
    String? sorted;
    await pumpGrid(
      tester,
      FakeGridSource.rows(2),
      onSortColumn: (column) => sorted = column,
      sortColumn: 'name',
      sortAscending: false,
    );

    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);

    await tester.tap(find.text('id'));
    await tester.pumpAndSettle();
    expect(sorted, 'id');
  });
}
