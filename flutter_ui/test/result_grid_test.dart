// 结果网格的 widget 测试。喂内存数据，不起 app、不连库。
//
// 真库行为（SQL 生成、拒绝规则、类型保真）由 cdata-core 的 Rust 测试保证，
// 这里只管界面这一层：渲染对不对、点了有没有反应、该拒绝的有没有说明原因。

import 'package:cdata_flutter/result_grid.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/layouts.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// 用鼠标拖。桌面上横向滚动不响应鼠标拖动，用触摸拖会和外层 ScrollView 抢手势
Future<void> mouseDrag(WidgetTester tester, Finder finder, Offset offset) async {
  final gesture = await tester.startGesture(tester.getCenter(finder), kind: PointerDeviceKind.mouse);
  // 先挪过拖动阈值，再一步到位
  await gesture.moveBy(Offset(offset.dx.sign * 20, 0));
  await tester.pump();
  await gesture.moveBy(Offset(offset.dx - offset.dx.sign * 20, 0));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

double widthOf(WidgetTester tester, String key) => tester.getSize(find.byKey(ValueKey(key))).width;

double leftOf(WidgetTester tester, String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dx;

List<String> namesOf(List<ColumnLayout> layout) => [for (final column in layout) column.name];

/// 接管系统剪贴板，读写都落在这个变量上
String? clipboardText;

void mockClipboard(WidgetTester tester) {
  clipboardText = null;
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      clipboardText = (call.arguments as Map)['text'] as String?;
      return null;
    }
    if (call.method == 'Clipboard.getData') {
      return {'text': clipboardText};
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

/// ⌘ + 某个键
Future<void> pressCommand(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await tester.pump();
}

Future<void> shiftTap(WidgetTester tester, Finder finder) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
  await tester.tap(finder);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
  await tester.pump();
}

Finder cell(int row, int column) => find.byKey(ValueKey('cell-$row-$column'));

void main() {
  testWidgets('内容恰好是 "NULL" 或 <…> 的文本按普通文本画，只有真正的 NULL 是占位样式', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(columns: [column('a'), column('b'), column('c')], totalRows: 1),
      rows: [
        [const CellValue.text('NULL'), const CellValue.null_(), const CellValue.text('<abc>')],
      ],
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ResultGrid(source: source))));
    await tester.pumpAndSettle();

    final nullTexts = tester.widgetList<Text>(find.text('NULL')).toList();
    expect(nullTexts, hasLength(2));
    final italic = [for (final text in nullTexts) text.style?.fontStyle == FontStyle.italic];
    // 一个是真实文本、一个是 NULL，样式必须不同
    expect(italic, unorderedEquals([true, false]));
    expect(tester.widget<Text>(find.text('<abc>')).style?.fontStyle, isNot(FontStyle.italic));
  });

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

  testWidgets('二进制单元格只能查看不能编辑', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(columns: [column('id'), column('data')], totalRows: 1),
      rows: [
        [CellValue.int(1), CellValue.bytes(bytesOf(4))],
      ],
    );
    await pumpGrid(tester, source);

    await doubleTap(tester, find.byKey(const ValueKey('cell-0-1')));
    await tester.pumpAndSettle();

    // 二进制打开的是只读的十六进制查看，不是编辑框
    expect(find.byType(TextField), findsNothing);
    expect(find.text('HEX 4'), findsOneWidget);
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

  testWidgets('点行号选中，确认后删除，行数以返回值为准', (tester) async {
    final source = FakeGridSource.rows(3);
    await pumpGrid(tester, source);

    await tester.tap(find.byKey(const ValueKey('row-number-0')));
    await tester.tap(find.byKey(const ValueKey('row-number-2')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除 2 行'));
    await tester.pumpAndSettle();
    expect(find.text('删除 2 行？'), findsOneWidget, reason: '删库前必须二次确认');

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(source.deletes, [
      [0, 2],
    ]);
    expect(find.text('1 行'), findsOneWidget);
    expect(find.text('用户2'), findsOneWidget);
    expect(find.text('用户1'), findsNothing);
    expect(find.textContaining('删除 '), findsNothing, reason: '删完选中要清空');
  });

  testWidgets('取消确认就一行都不删', (tester) async {
    final source = FakeGridSource.rows(2);
    await pumpGrid(tester, source);

    await tester.tap(find.byKey(const ValueKey('row-number-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除 1 行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(source.deletes, isEmpty);
    expect(find.text('2 行'), findsOneWidget);
  });

  testWidgets('再点一次行号取消选中', (tester) async {
    await pumpGrid(tester, FakeGridSource.rows(2));

    await tester.tap(find.byKey(const ValueKey('row-number-0')));
    await tester.pumpAndSettle();
    expect(find.text('删除 1 行'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('row-number-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除 '), findsNothing);
  });

  testWidgets('新增行区分默认、NULL 和值', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(
        columns: [column('id'), column('name'), column('note')],
        totalRows: 1,
      ),
      rows: [
        [CellValue.int(1), CellValue.text('a'), CellValue.null_()],
      ],
    );
    await pumpGrid(tester, source);

    await tester.tap(find.text('新增行'));
    await tester.pumpAndSettle();

    // id 不动，保持「默认」；name 打字自动切成「值」；note 显式选 NULL
    await tester.enterText(find.byKey(const ValueKey('insert-field-1')), '新用户');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('insert-mode-2')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('NULL').last);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('插入'));
    await tester.pumpAndSettle();

    expect(source.inserts, [
      [null, const CellValue.text('新用户'), const CellValue.null_()],
    ]);
    expect(find.text('2 行'), findsOneWidget);
    expect(find.text('新用户'), findsOneWidget);
  });

  testWidgets('新增行失败要显示原因', (tester) async {
    final source = FakeGridSource.rows(1)..editError = '主键列 id 没有填值，且不是自增列';
    await pumpGrid(tester, source);

    await tester.tap(find.text('新增行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('插入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('不是自增列'), findsOneWidget);
    expect(find.text('1 行'), findsOneWidget);
  });

  testWidgets('只读结果集没有增删入口', (tester) async {
    final source = FakeGridSource.rows(
      2,
      editability: const Editability.readOnly('结果集来自多张表'),
    );
    await pumpGrid(tester, source);

    await tester.tap(find.byKey(const ValueKey('row-number-0')));
    await tester.pumpAndSettle();

    expect(find.text('新增行'), findsNothing);
    expect(find.textContaining('删除 '), findsNothing);
  });

  testWidgets('拖列边改宽度，松手后记住', (tester) async {
    final source = FakeGridSource.rows(2);
    await pumpGrid(tester, source);

    await mouseDrag(tester, find.byKey(const ValueKey('resize-1')), const Offset(60, 0));

    expect(widthOf(tester, 'cell-0-1'), closeTo(230, 1), reason: '数据列要跟着表头一起变宽');
    expect(widthOf(tester, 'header-1'), closeTo(230, 1));
    expect(source.layoutSaves, hasLength(1), reason: '拖动过程中不存，松手存一次');
    expect(namesOf(source.layoutSaves.last), ['id', 'name']);
    expect(source.layoutSaves.last[1].width, closeTo(230, 1));
  });

  testWidgets('列宽有下限，拖不没', (tester) async {
    await pumpGrid(tester, FakeGridSource.rows(2));

    await mouseDrag(tester, find.byKey(const ValueKey('resize-1')), const Offset(-400, 0));
    expect(widthOf(tester, 'cell-0-1'), greaterThanOrEqualTo(48));
  });

  testWidgets('双击列边按内容自适应，超长内容有上限', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(columns: [column('id'), column('name'), column('note')], totalRows: 1),
      rows: [
        [CellValue.int(1), CellValue.text('ab'), CellValue.text('x' * 300)],
      ],
    );
    await pumpGrid(tester, source);

    await doubleTap(tester, find.byKey(const ValueKey('resize-1')));
    await tester.pumpAndSettle();
    await doubleTap(tester, find.byKey(const ValueKey('resize-2')));
    await tester.pumpAndSettle();

    expect(widthOf(tester, 'cell-0-1'), lessThan(170), reason: '短内容应该收窄');
    expect(widthOf(tester, 'cell-0-2'), 600, reason: '超长内容不能把列撑到没边');
    expect(source.layoutSaves, hasLength(2));
  });

  testWidgets('拖列头换顺序，数据列跟着换并记住', (tester) async {
    final source = FakeGridSource.rows(2);
    await pumpGrid(tester, source);

    // 把 name 拖到 id 上
    await mouseDrag(tester, find.text('name'), const Offset(-170, 0));

    expect(leftOf(tester, 'cell-0-1'), lessThan(leftOf(tester, 'cell-0-0')));
    expect(leftOf(tester, 'header-1'), lessThan(leftOf(tester, 'header-0')));
    expect(namesOf(source.savedLayout), ['name', 'id']);

    // 换了顺序，双击编辑的还是原来那一列
    await doubleTap(tester, find.text('用户1'));
    await tester.enterText(find.byType(TextField), '新名字');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(source.edits.single.$2, 1);
  });

  testWidgets('打开时套用记住的布局，没记过的新列排在最后', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(columns: [column('id'), column('name'), column('note')], totalRows: 1),
      rows: [
        [CellValue.int(1), CellValue.text('a'), CellValue.text('b')],
      ],
    )..savedLayout = [
        ColumnLayout(name: 'name', width: 250),
        ColumnLayout(name: 'dropped_column', width: 999),
        ColumnLayout(name: 'id', width: 90),
      ];
    await pumpGrid(tester, source);

    expect(widthOf(tester, 'cell-0-1'), 250);
    expect(widthOf(tester, 'cell-0-0'), 90);
    expect(widthOf(tester, 'cell-0-2'), 170, reason: 'note 没记过，用默认宽度');
    expect(leftOf(tester, 'cell-0-1'), lessThan(leftOf(tester, 'cell-0-0')));
    expect(leftOf(tester, 'cell-0-0'), lessThan(leftOf(tester, 'cell-0-2')));
  });

  testWidgets('同样的列重跑（排序）保留当前布局', (tester) async {
    final first = FakeGridSource.rows(2);
    await pumpGrid(tester, first);
    await mouseDrag(tester, find.byKey(const ValueKey('resize-1')), const Offset(60, 0));

    // 排序会换一个新结果集，列不变；新结果集里读不到布局（比如 JOIN 结果不记）
    await pumpGrid(tester, FakeGridSource.rows(2));
    expect(widthOf(tester, 'cell-0-1'), closeTo(230, 1));
  });

  testWidgets('点一格再 Shift 点一格选出区域，⌘C 复制成 TSV', (tester) async {
    mockClipboard(tester);
    final source = FakeGridSource.rows(3);
    await pumpGrid(tester, source);

    await tester.tap(cell(0, 0));
    await shiftTap(tester, cell(1, 1));
    await pressCommand(tester, LogicalKeyboardKey.keyC);
    await tester.pumpAndSettle();

    expect(source.copies.single.$1, 0);
    expect(source.copies.single.$2, 2);
    expect(source.copies.single.$3, [0, 1]);
    expect(clipboardText, '1\t用户1\n2\t用户2');
    expect(find.text('已复制 2 行 × 2 列'), findsOneWidget);
  });

  testWidgets('反方向拖出的选区一样按左上到右下复制', (tester) async {
    mockClipboard(tester);
    final source = FakeGridSource.rows(3);
    await pumpGrid(tester, source);

    await tester.tap(cell(2, 1));
    await shiftTap(tester, cell(1, 0));
    await pressCommand(tester, LogicalKeyboardKey.keyC);
    await tester.pumpAndSettle();

    expect(source.copies.single.$1, 1);
    expect(source.copies.single.$2, 2);
    expect(source.copies.single.$3, [0, 1]);
  });

  testWidgets('换了列顺序，复制按屏幕上的顺序', (tester) async {
    mockClipboard(tester);
    final source = FakeGridSource.rows(2)
      ..savedLayout = [ColumnLayout(name: 'name', width: 170), ColumnLayout(name: 'id', width: 170)];
    await pumpGrid(tester, source);

    await tester.tap(cell(0, 1));
    await shiftTap(tester, cell(0, 0));
    await pressCommand(tester, LogicalKeyboardKey.keyC);
    await tester.pumpAndSettle();

    expect(source.copies.single.$3, [1, 0]);
    expect(clipboardText, '用户1\t1');
  });

  testWidgets('编辑框里的 ⌘C 归编辑框，网格不接管', (tester) async {
    mockClipboard(tester);
    final source = FakeGridSource.rows(2);
    await pumpGrid(tester, source);

    await doubleTap(tester, cell(0, 1));
    expect(find.byType(TextField), findsOneWidget);
    // 按下单元格时网格先拿了焦点，编辑框必须把焦点抢过来，否则打字没反应
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasPrimaryFocus, isTrue, reason: '双击进入编辑后焦点要在编辑框里');
    await pressCommand(tester, LogicalKeyboardKey.keyC);
    await tester.pump(const Duration(milliseconds: 100));

    expect(source.copies, isEmpty);
  });

  testWidgets('⌘V 确认后从选区左上角铺开粘贴', (tester) async {
    mockClipboard(tester);
    clipboardText = '甲\n乙\n';
    final source = FakeGridSource.rows(3);
    await pumpGrid(tester, source);

    await tester.tap(cell(1, 1));
    await pressCommand(tester, LogicalKeyboardKey.keyV);
    await tester.pumpAndSettle();
    expect(find.text('粘贴 2 行 × 1 列？'), findsOneWidget, reason: '写库前必须确认');

    await tester.tap(find.widgetWithText(FilledButton, '粘贴'));
    await tester.pumpAndSettle();

    expect(source.pastes.single.$1, 1);
    expect(source.pastes.single.$2, [1]);
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    expect(find.text('已写入 2 个单元格'), findsOneWidget);
  });

  testWidgets('取消粘贴就一格都不写', (tester) async {
    mockClipboard(tester);
    clipboardText = '甲';
    final source = FakeGridSource.rows(2);
    await pumpGrid(tester, source);

    await tester.tap(cell(0, 1));
    await pressCommand(tester, LogicalKeyboardKey.keyV);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(source.pastes, isEmpty);
    expect(find.text('用户1'), findsOneWidget);
  });

  testWidgets('粘贴放不下时直接说明原因，不弹确认', (tester) async {
    mockClipboard(tester);
    final source = FakeGridSource.rows(2);
    await pumpGrid(tester, source);

    // 行超出
    clipboardText = 'x\ny\nz';
    await tester.tap(cell(1, 1));
    await pressCommand(tester, LogicalKeyboardKey.keyV);
    await tester.pumpAndSettle();
    expect(find.textContaining('超出结果集末尾'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    // 列超出
    clipboardText = 'a\tb';
    await pressCommand(tester, LogicalKeyboardKey.keyV);
    await tester.pumpAndSettle();
    expect(find.textContaining('放不下'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(source.pastes, isEmpty);
  });

  testWidgets('只读结果集粘贴时说明原因', (tester) async {
    mockClipboard(tester);
    clipboardText = 'x';
    final source = FakeGridSource.rows(
      2,
      editability: const Editability.readOnly('结果集来自多张表（orders 和 users），不能编辑'),
    );
    await pumpGrid(tester, source);

    await tester.tap(cell(0, 1));
    await pressCommand(tester, LogicalKeyboardKey.keyV);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(source.pastes, isEmpty);
    expect(find.textContaining('多张表'), findsOneWidget);
  });

  testWidgets('粘贴失败要把错误显示出来', (tester) async {
    mockClipboard(tester);
    clipboardText = 'x';
    final source = FakeGridSource.rows(2)..editError = '第 1 行预期修改 1 行，实际 0 行，已整体回滚';
    await pumpGrid(tester, source);

    await tester.tap(cell(0, 1));
    await pressCommand(tester, LogicalKeyboardKey.keyV);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '粘贴'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已整体回滚'), findsOneWidget);
  });
}
