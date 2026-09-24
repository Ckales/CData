// 按列类别打开对应编辑器的 widget 测试。JSON 校验、可选值读取的真实行为由 cdata-core 保证。

import 'package:cdata_flutter/result_grid.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// 一行数据：id + 各种类别的列
FakeGridSource typedSource() {
  final source = FakeGridSource(
    summary: summaryOf(
      columns: [
        column('id', kind: ColumnKind.number),
        column('meta', kind: ColumnKind.json),
        column('status', kind: ColumnKind.enum_),
        column('tags', kind: ColumnKind.set_),
        column('day', kind: ColumnKind.date),
        column('at', kind: ColumnKind.dateTime),
        column('blob', isBinary: true),
        column('raw', isBinary: true),
      ],
      totalRows: 1,
    ),
    rows: [
      [
        CellValue.int(1),
        const CellValue.text('{"a":1}'),
        const CellValue.text('draft'),
        const CellValue.text('x,z'),
        const CellValue.text('2026-01-02'),
        const CellValue.text('2026-01-02 08:30:00.123456'),
        const CellValue.null_(),
        CellValue.bytes(bytesOf(4)),
      ],
    ],
  );
  source.choices[2] = ['draft', 'paid', 'refunded'];
  source.choices[3] = ['x', 'y', 'z'];
  return source;
}

Future<void> pumpTyped(WidgetTester tester, FakeGridSource source) async {
  tester.view.physicalSize = const Size(2400, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.light), home: Scaffold(body: ResultGrid(source: source))));
  await tester.pumpAndSettle();
}

Future<void> openEditor(WidgetTester tester, int column) async {
  final finder = find.byKey(ValueKey('cell-0-$column'));
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('JSON：不合法不让存，格式化后保存写的是编辑框里的文本', (tester) async {
    final source = typedSource();
    await pumpTyped(tester, source);
    await openEditor(tester, 1);

    expect(find.text('meta（JSON）'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('json-text')), '{"a":');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('不是合法的 JSON'), findsOneWidget);
    expect(source.edits, isEmpty, reason: '不合法的 JSON 不能写进库');

    await tester.enterText(find.byKey(const ValueKey('json-text')), '{"a":2}');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('格式化'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(source.edits.single.$2, 1);
    expect(source.edits.single.$3, const CellValue.text('{\n"a":2}'));
  });

  testWidgets('编辑器里的「写入 NULL」写的是 NULL，取消什么都不写', (tester) async {
    final source = typedSource();
    await pumpTyped(tester, source);

    await openEditor(tester, 1);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(source.edits, isEmpty);

    await openEditor(tester, 1);
    await tester.tap(find.text('写入 NULL'));
    await tester.pumpAndSettle();
    expect(source.edits.single.$3, const CellValue.null_());
  });

  testWidgets('ENUM：从定义里的可选值里点选', (tester) async {
    final source = typedSource();
    await pumpTyped(tester, source);
    await openEditor(tester, 2);

    expect(find.text('refunded'), findsOneWidget);
    await tester.tap(find.text('paid'));
    await tester.pumpAndSettle();
    expect(source.edits.single.$3, const CellValue.text('paid'));
  });

  testWidgets('SET：多选按定义顺序拼起来', (tester) async {
    final source = typedSource();
    await pumpTyped(tester, source);
    await openEditor(tester, 3);

    // 原值 x,z：勾上 y、去掉 x
    await tester.tap(find.widgetWithText(CheckboxListTile, 'y'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'x'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(source.edits.single.$3, const CellValue.text('y,z'));
  });

  testWidgets('读不到可选值时说明原因，不弹空编辑器', (tester) async {
    final source = typedSource();
    source.choices.remove(2);
    await pumpTyped(tester, source);
    await openEditor(tester, 2);

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('不是 ENUM'), findsOneWidget);
  });

  testWidgets('DATETIME：选日期只换日期部分，时间和微秒原样保留', (tester) async {
    final source = typedSource();
    await pumpTyped(tester, source);
    await openEditor(tester, 5);

    await tester.tap(find.byTooltip('选择日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(source.edits.single.$3, const CellValue.text('2026-01-15 08:30:00.123456'));
  });

  testWidgets('DATE：选日期写 YYYY-MM-DD', (tester) async {
    final source = typedSource();
    await pumpTyped(tester, source);
    await openEditor(tester, 4);

    await tester.tap(find.byTooltip('选择日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(source.edits.single.$3, const CellValue.text('2026-01-20'));
  });

  testWidgets('二进制内容打开十六进制查看，不能编辑', (tester) async {
    final source = typedSource();
    await pumpTyped(tester, source);
    await openEditor(tester, 7);

    expect(find.text('raw（4 字节）'), findsOneWidget);
    expect(find.text('HEX 4'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(source.edits, isEmpty);
  });

  testWidgets('二进制列里的 NULL 也不能当文本编辑', (tester) async {
    final source = typedSource();
    await pumpTyped(tester, source);
    await openEditor(tester, 6);

    expect(find.byType(TextField), findsNothing, reason: '往 BLOB 里敲文本会写进 UTF-8 字节');
    expect(find.textContaining('二进制内容暂不支持'), findsOneWidget);
  });

  testWidgets('TIME：原文带着小数秒打开，错误由校验函数给出，不合法不让存', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(
        columns: [column('id', kind: ColumnKind.number), column('dur', kind: ColumnKind.time, decimals: 3)],
        totalRows: 1,
      ),
      rows: [
        [CellValue.int(1), const CellValue.text('-120:30:00.125000')],
      ],
    );
    // 校验规则在 core；这里换一个假的，只看界面把它的结论显示出来、按它拦住保存
    final checks = <(String, int)>[];
    String? fakeCheck(String text, int fsp) {
      checks.add((text, fsp));
      return text.startsWith('9') ? 'TIME 的范围是 -838:59:59 到 838:59:59' : null;
    }

    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.light), home: Scaffold(body: ResultGrid(source: source, checkTime: fakeCheck))));
    await tester.pumpAndSettle();
    await openEditor(tester, 1);

    expect(find.text('dur（TIME）'), findsOneWidget, reason: 'TIME 走专门的编辑器，不是网格里的普通文本框');
    final field = tester.widget<TextField>(find.byKey(const ValueKey('time-text')));
    expect(field.controller!.text, '-120:30:00.125000', reason: '小数秒原样带进来，不截断');
    expect(checks.first, ('-120:30:00.125000', 3), reason: '列的小数秒位数要交给校验');
    expect(find.textContaining('保留 3 位小数秒'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('time-text')), '900:00:00');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('TIME 的范围'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(source.edits, isEmpty);

    await tester.enterText(find.byKey(const ValueKey('time-text')), '100:00:00.5');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(source.edits.single.$3, const CellValue.text('100:00:00.5'), reason: '写的是原文，不补零不改写');
  });
}
