// 导出入口的 widget 测试。文件怎么写（引号、编码、INSERT）由 cdata-core 的测试保证，
// 这里管界面：选项传得对不对、范围和列顺序对不对、截断和失败有没有说清楚。

import 'package:cdata_flutter/result_grid.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/layouts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<List<String>> pumpExportGrid(WidgetTester tester, FakeGridSource source, {String? savePath = '/tmp/out'}) async {
  final asked = <String>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ResultGrid(
        source: source,
        pickSavePath: (suggestedName) async {
          asked.add(suggestedName);
          return savePath;
        },
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return asked;
}

Future<void> choose(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> startExport(WidgetTester tester) async {
  await tester.tap(find.text('导出'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('默认导出全部行，列按屏幕顺序，NULL 默认写成 NULL', (tester) async {
    final source = FakeGridSource.rows(3)
      ..savedLayout = [ColumnLayout(name: 'name', width: 170), ColumnLayout(name: 'id', width: 170)];
    final asked = await pumpExportGrid(tester, source);

    await startExport(tester);
    expect(find.text('全部 3 行'), findsOneWidget);
    await tester.tap(find.text('导出…'));
    await tester.pumpAndSettle();

    expect(asked, ['orders.csv'], reason: '可编辑结果用来源表名当文件名');
    final export = source.exports.single;
    expect(export.rowStart, 0);
    expect(export.rowCount, isNull, reason: 'null 表示导到末尾');
    expect(export.columns, [1, 0]);
    expect(export.options.format, ExportFormat.csv);
    expect(export.options.nullText, 'NULL');
    expect(export.options.encoding, ExportEncoding.utf8);
    expect(find.text('已导出 3 行到 /tmp/out'), findsOneWidget);
  });

  testWidgets('有选区时默认只导出选中区域', (tester) async {
    final source = FakeGridSource.rows(5);
    await pumpExportGrid(tester, source);

    await tester.tap(find.byKey(const ValueKey('cell-1-1')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.tap(find.byKey(const ValueKey('cell-3-1')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();

    await startExport(tester);
    expect(find.text('选中区域（3 行 × 1 列）'), findsOneWidget);
    await tester.tap(find.text('导出…'));
    await tester.pumpAndSettle();

    final export = source.exports.single;
    expect(export.rowStart, 1);
    expect(export.rowCount, 3);
    expect(export.columns, [1]);
  });

  testWidgets('SQL 导出带表名，编码可选', (tester) async {
    final source = FakeGridSource.rows(2);
    final asked = await pumpExportGrid(tester, source);

    await startExport(tester);
    await choose(tester, 'export-format', 'SQL INSERT');
    await choose(tester, 'export-encoding', 'GBK');
    await tester.enterText(find.byKey(const ValueKey('export-table')), 'orders_backup');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('导出…'));
    await tester.pumpAndSettle();

    expect(asked, ['orders.sql']);
    expect(source.exports.single.options.format, ExportFormat.sqlInsert);
    expect(source.exports.single.options.encoding, ExportEncoding.gbk);
    expect(source.exports.single.options.tableName, 'orders_backup');
  });

  testWidgets('取消保存对话框就不导出', (tester) async {
    final source = FakeGridSource.rows(2);
    await pumpExportGrid(tester, source, savePath: null);

    await startExport(tester);
    await tester.tap(find.text('导出…'));
    await tester.pumpAndSettle();
    expect(source.exports, isEmpty);
  });

  testWidgets('结果集被截断过要醒目地说明文件不完整', (tester) async {
    final source = FakeGridSource.rows(2)..exportTruncated = true;
    await pumpExportGrid(tester, source);

    await startExport(tester);
    await tester.tap(find.text('导出…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('文件里不是全部数据'), findsOneWidget);
  });

  testWidgets('导出失败要显示原因', (tester) async {
    final source = FakeGridSource.rows(2)..editError = '第 2 行 里有 GBK 表示不了的字符';
    await pumpExportGrid(tester, source);

    await startExport(tester);
    await tester.tap(find.text('导出…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('导出失败：'), findsOneWidget);
    expect(find.textContaining('GBK 表示不了'), findsOneWidget);
  });

  testWidgets('只读结果集也能导出，文件名用 result', (tester) async {
    final source = FakeGridSource.rows(2, editability: const Editability.readOnly('结果集来自多张表'));
    final asked = await pumpExportGrid(tester, source);

    await startExport(tester);
    await tester.tap(find.text('导出…'));
    await tester.pumpAndSettle();
    expect(asked, ['result.csv']);
    expect(source.exports, hasLength(1));
  });
}
