// 导入对话框的 widget 测试。CSV 怎么解析、NULL 怎么认、映射怎么校验、怎么写库
// 由 cdata-core 的测试保证，这里管界面：选项和映射传得对不对、进度和结果有没有说清楚。

import 'package:cdata_flutter/import_dialog.dart';
import 'package:cdata_flutter/src/rust/api/csv_import.dart';
import 'package:cdata_flutter/src/rust/api/db.dart' show ExportEncoding;
import 'package:cdata_flutter/src/rust/api/value.dart' show DisplayCell;
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

ImportTarget targetOf({bool strict = true}) {
  return ImportTarget(
    schema: 'shop',
    table: 'orders',
    columns: [
      targetColumn('id', autoIncrement: true),
      targetColumn('name', mandatory: true),
      targetColumn('amount'),
      targetColumn('total', generated: true),
    ],
    sqlMode: strict ? 'STRICT_TRANS_TABLES' : '',
    strict: strict,
  );
}

DisplayCell text(String value) => DisplayCell(text: value, placeholder: false);

const nullCell = DisplayCell(text: 'NULL', placeholder: true);

CsvPreview previewOf({List<String> header = const ['name', 'amount', 'extra'], String? error}) {
  return CsvPreview(
    header: header,
    columnCount: BigInt.from(3),
    rows: [
      PreviewRow(line: BigInt.from(2), cells: [text('张三'), text('1.50'), nullCell]),
      PreviewRow(line: BigInt.from(3), cells: [text('NULL'), text('2.00'), text('x')]),
      PreviewRow(line: BigInt.from(4), cells: [text('李四')], error: '有 1 列，应该是 3 列'),
    ],
    error: error,
  );
}

ImportStatus finished({
  ImportOutcome outcome = const ImportOutcome.completed(),
  int read = 3,
  int inserted = 3,
  int failed = 0,
  List<RowError> errors = const [],
}) {
  return ImportStatus.finished(ImportReport(
    progress: importProgress(read: read, inserted: inserted, failed: failed, bytes: 100),
    outcome: outcome,
    errors: errors,
  ));
}

FakeImportSource sourceOf({bool strict = true, List<ImportStatus>? statuses, CsvPreview? preview}) {
  return FakeImportSource(
    targetResult: targetOf(strict: strict),
    previewResult: preview ?? previewOf(),
    statuses: statuses ?? [finished()],
  );
}

/// 打开对话框，返回一个取结果的函数（对话框关掉之前是 null）
Future<bool? Function()> openDialog(
  WidgetTester tester,
  FakeImportSource source, {
  List<String>? savedPaths,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  bool? result;
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(Brightness.light),
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await showImportDialog(
            context,
            source: source,
            database: 'shop',
            table: 'orders',
            pickFile: () async => '/tmp/orders.csv',
            pickSavePath: (suggestedName) async {
              savedPaths?.add(suggestedName);
              return '/tmp/$suggestedName';
            },
          );
        },
        child: const Text('打开'),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return () => result;
}

Future<void> choose(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> pickAndPreview(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('import-pick-file')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('import-next')));
  await tester.pumpAndSettle();
}

/// 进度每 300ms 轮询一次，推几轮虚拟时钟
Future<void> pollRounds(WidgetTester tester, int rounds) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  testWidgets('选文件、按表头建议映射、改映射、导入完成', (tester) async {
    final source = sourceOf(statuses: [
      ImportStatus.running(importProgress(read: 1, inserted: 0, bytes: 40)),
      finished(),
    ]);
    final result = await openDialog(tester, source);

    expect(find.text('导入到 shop.orders'), findsOneWidget);
    await pickAndPreview(tester);

    final (path, options) = source.previews.single;
    expect(path, '/tmp/orders.csv');
    expect(options.encoding, ExportEncoding.utf8);
    expect(options.delimiter, ',');
    expect(options.nullText, 'NULL', reason: '默认和导出一致');
    expect(options.header, isTrue);

    // 预览：NULL 是占位，内容恰好是 NULL 的文本不是；列数不对的行标出来
    expect(find.text('张三'), findsOneWidget);
    expect(find.text('有 1 列，应该是 3 列'), findsOneWidget);
    final nullTexts = tester.widgetList<Text>(find.text('NULL')).toList();
    expect(nullTexts.length, 2);
    expect(nullTexts.where((t) => t.style?.fontStyle == FontStyle.italic).length, 1);

    // 按表头建议：name → name（必填），amount → amount，extra 没有对应列就跳过
    expect(find.text('name（必填）'), findsOneWidget);
    expect(find.text('跳过'), findsOneWidget);
    // 建议可以改：extra 改成写进 id
    await choose(tester, 'import-map-2', 'id');

    await tester.tap(find.byKey(const ValueKey('import-start')));
    await tester.pump();
    final request = source.starts.single;
    expect(request.mapping, [1, 2, 0]);
    expect(request.onError, OnError.rollbackAll);
    expect(request.schema, 'shop');
    expect(request.table, 'orders');
    expect(find.byKey(const ValueKey('import-progress')), findsOneWidget);
    expect(find.textContaining('全部完成后才提交'), findsOneWidget);

    await pollRounds(tester, 2);
    expect(find.text('导入完成，写入 3 行'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-save-errors')), findsNothing, reason: '没有失败行就不给导出');

    await tester.tap(find.byKey(const ValueKey('import-done')));
    await tester.pumpAndSettle();
    expect(result(), isTrue, reason: '有行提交了，调用方要刷新');
    expect(source.closes, [7], reason: '关掉对话框要清掉任务和错误行临时文件');
  });

  testWidgets('编码、分隔符、NULL 写法、表头都照用户选的传；没有表头不按位置猜映射', (tester) async {
    final source = sourceOf(preview: previewOf(header: const []));
    await openDialog(tester, source);

    await choose(tester, 'import-encoding', 'GBK');
    await choose(tester, 'import-delimiter', '制表符');
    await choose(tester, 'import-null', r'\N');
    await tester.tap(find.byKey(const ValueKey('import-header')));
    await tester.pump();
    await pickAndPreview(tester);

    final options = source.previews.single.$2;
    expect(options.encoding, ExportEncoding.gbk);
    expect(options.delimiter, '\t');
    expect(options.nullText, r'\N');
    expect(options.header, isFalse);

    expect(find.text('第 1 列'), findsOneWidget);
    expect(find.text('跳过'), findsNWidgets(3));
    expect(find.textContaining('name 不允许 NULL 也没有默认值'), findsOneWidget);

    await choose(tester, 'import-on-error', '跳过错误行继续：每批单独提交');
    await choose(tester, 'import-map-0', 'name（必填）');
    expect(find.textContaining('不允许 NULL 也没有默认值'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('import-start')));
    await tester.pump();
    expect(source.starts.single.mapping, [1, null, null]);
    expect(source.starts.single.onError, OnError.skipRow);
    await pollRounds(tester, 1);
  });

  testWidgets('sql_mode 不是 strict 时明确告诉用户会临时加 STRICT_ALL_TABLES', (tester) async {
    final source = sourceOf(strict: false);
    await openDialog(tester, source);
    await pickAndPreview(tester);
    expect(find.byKey(const ValueKey('import-sql-mode')), findsOneWidget);
    expect(find.textContaining('STRICT_ALL_TABLES'), findsOneWidget);
    expect(find.textContaining('（空）'), findsOneWidget);
  });

  testWidgets('strict 时不打扰', (tester) async {
    final source = sourceOf();
    await openDialog(tester, source);
    await pickAndPreview(tester);
    expect(find.byKey(const ValueKey('import-sql-mode')), findsNothing);
  });

  testWidgets('预览范围内读不下去的错误带行号显示出来', (tester) async {
    final source = sourceOf(preview: previewOf(error: '第 5 行开始的引号到文件末尾都没有闭合'));
    await openDialog(tester, source);
    await pickAndPreview(tester);
    expect(find.text('第 5 行开始的引号到文件末尾都没有闭合。导入会在这里停下'), findsOneWidget);
  });

  testWidgets('core 拒绝开始时留在映射页并显示原因', (tester) async {
    final source = sourceOf()..startError = '表列 name 被映射了不止一次';
    await openDialog(tester, source);
    await pickAndPreview(tester);
    await tester.tap(find.byKey(const ValueKey('import-start')));
    await tester.pumpAndSettle();
    expect(find.textContaining('被映射了不止一次'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-start')), findsOneWidget);
  });

  testWidgets('目标表不能导入时说明原因，不能往下走', (tester) async {
    final source = sourceOf()..targetError = '表 orders 的引擎（MyISAM）不支持事务';
    await openDialog(tester, source);
    await tester.tap(find.byKey(const ValueKey('import-pick-file')));
    await tester.pumpAndSettle();
    expect(find.textContaining('MyISAM'), findsOneWidget);
    final next = tester.widget<FilledButton>(find.byKey(const ValueKey('import-next')));
    expect(next.onPressed, isNull);
  });

  testWidgets('整体回滚时列出失败原因，可以导出错误行', (tester) async {
    final source = sourceOf(statuses: [
      finished(
        outcome: const ImportOutcome.rolledBack(),
        inserted: 0,
        failed: 2,
        errors: [
          RowError(line: BigInt.from(3), reason: '列 name 不允许 NULL'),
          RowError(line: BigInt.from(9), reason: 'MySQL 错误 1406：Data too long'),
        ],
      ),
    ]);
    final saved = <String>[];
    final result = await openDialog(tester, source, savedPaths: saved);
    await pickAndPreview(tester);
    await tester.tap(find.byKey(const ValueKey('import-start')));
    await tester.pump();
    await pollRounds(tester, 1);

    expect(find.text('有 2 行失败，已整体回滚，没有写入任何行'), findsOneWidget);
    expect(find.text('第 3 行：列 name 不允许 NULL'), findsOneWidget);
    expect(find.text('第 9 行：MySQL 错误 1406：Data too long'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-save-errors')));
    await tester.pumpAndSettle();
    expect(saved, ['orders_errors.csv']);
    expect(source.saves.single, (7, '/tmp/orders_errors.csv'));
    expect(find.text('已把 2 行失败的数据导出到 /tmp/orders_errors.csv'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-done')));
    await tester.pumpAndSettle();
    expect(result(), isFalse, reason: '回滚了，表没变');
  });

  testWidgets('导入中只能取消，取消后说明提交了什么', (tester) async {
    final source = sourceOf(statuses: [ImportStatus.running(importProgress(read: 1, bytes: 10))]);
    await openDialog(tester, source);
    await pickAndPreview(tester);
    await tester.tap(find.byKey(const ValueKey('import-start')));
    await tester.pump();
    await pollRounds(tester, 2);
    expect(find.byKey(const ValueKey('import-done')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('import-cancel')));
    await tester.pump();
    expect(source.cancels, [7]);
    expect(find.text('正在取消…'), findsOneWidget);

    await pollRounds(tester, 1);
    expect(find.text('导入中途停止：已取消。没有提交任何行'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-done')));
    await tester.pumpAndSettle();
  });
}
