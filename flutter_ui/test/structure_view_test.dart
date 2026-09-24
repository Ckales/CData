// 表结构对话框的 widget 测试。结构怎么从 information_schema 读由 cdata-core 的真库测试保证。

import 'package:cdata_flutter/src/rust/api/schema.dart';
import 'package:cdata_flutter/structure_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

ColumnDef columnDef(String name, String type, DefaultValue value, {bool nullable = false, String extra = ''}) {
  return ColumnDef(
    name: name,
    columnType: type,
    nullable: nullable,
    default_: value,
    extra: extra,
    comment: '',
    collation: null,
  );
}

TableStructure sampleStructure() {
  return TableStructure(
    columns: [
      columnDef('id', 'int unsigned', const DefaultValue.noDefault(), extra: 'auto_increment'),
      columnDef('title', 'varchar(100)', const DefaultValue.literal('')),
      columnDef('body', 'text', const DefaultValue.null_(), nullable: true),
      columnDef('created_at', 'datetime', const DefaultValue.expression('CURRENT_TIMESTAMP')),
    ],
    indexes: [
      const IndexDef(name: 'PRIMARY', unique: true, columns: ['id'], indexType: 'BTREE', comment: ''),
      const IndexDef(name: 'idx_title', unique: false, columns: ['title(10)'], indexType: 'BTREE', comment: ''),
    ],
    foreignKeys: const [],
    createSql: 'CREATE TABLE `posts` (\n  `id` int unsigned NOT NULL AUTO_INCREMENT\n)',
  );
}

Future<void> pumpStructure(WidgetTester tester, FakeSchemaSource source, String table) async {
  tester.view.physicalSize = const Size(2000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showTableStructure(context, source: source, database: 'shop', table: table),
          child: const Text('打开'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('四种默认值显示得能区分开', (tester) async {
    final source = FakeSchemaSource.simple()..structures['posts'] = sampleStructure();
    await pumpStructure(tester, source, 'posts');

    expect(find.text('shop.posts'), findsOneWidget);
    expect(find.text('列 4'), findsOneWidget);
    expect(find.text('无'), findsOneWidget, reason: '没有默认值');
    expect(find.text("''"), findsOneWidget, reason: '空串默认值要带引号，不能显示成空白');
    expect(find.text('NULL'), findsOneWidget);
    expect(find.text('CURRENT_TIMESTAMP'), findsOneWidget, reason: '表达式不带引号');
    expect(find.byIcon(Icons.key), findsOneWidget, reason: '主键列有标记');
  });

  testWidgets('索引、外键、建表语句各一页，建表语句能复制', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final source = FakeSchemaSource.simple()..structures['posts'] = sampleStructure();
    await pumpStructure(tester, source, 'posts');

    await tester.tap(find.text('索引 2'));
    await tester.pumpAndSettle();
    expect(find.text('title(10)'), findsOneWidget);

    await tester.tap(find.text('外键 0'));
    await tester.pumpAndSettle();
    expect(find.text('没有外键'), findsOneWidget);

    await tester.tap(find.text('建表语句'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, startsWith('CREATE TABLE `posts`'));
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('读结构失败要显示原因', (tester) async {
    await pumpStructure(tester, FakeSchemaSource.simple(), 'missing');
    expect(find.textContaining('表 missing 不存在'), findsOneWidget);
  });
}
