// 表结构编辑器的 widget 测试。DDL 怎么生成、危险操作怎么判定由 cdata-core 的测试保证，
// 这里只验证界面把改动正确拼成草稿、预览和执行的流程、各种提示显示出来。

import 'package:cdata_flutter/src/rust/api/schema.dart';
import 'package:cdata_flutter/structure_view.dart';
import 'package:flutter/material.dart';
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

TableStructure postsStructure() {
  return TableStructure(
    columns: [
      columnDef('id', 'int unsigned', const DefaultValue.noDefault(), extra: 'auto_increment'),
      columnDef('title', 'varchar(100)', const DefaultValue.literal('')),
      columnDef('body', 'text', const DefaultValue.null_(), nullable: true),
    ],
    indexes: const [
      IndexDef(
        name: 'PRIMARY',
        unique: true,
        columns: ['id'],
        parts: [IndexPart(column: 'id', descending: false)],
        indexType: 'BTREE',
        comment: '',
      ),
      IndexDef(
        name: 'idx_title',
        unique: false,
        columns: ['title(10)'],
        parts: [IndexPart(column: 'title', prefix: 10, descending: false)],
        indexType: 'BTREE',
        comment: '',
      ),
    ],
    foreignKeys: const [],
    createSql: 'CREATE TABLE `posts` (…)',
    tableCollation: 'utf8mb4_0900_ai_ci',
  );
}

/// 编辑态里 TextField 光标一直在闪，不能 pumpAndSettle，用有限次 pump
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<FakeSchemaSource> openEditor(WidgetTester tester, {VoidCallback? onAltered}) async {
  tester.view.physicalSize = const Size(2000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final source = FakeSchemaSource.simple()..structures['posts'] = postsStructure();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showTableStructure(
            context,
            source: source,
            database: 'shop',
            table: 'posts',
            onAltered: onAltered,
          ),
          child: const Text('打开'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('编辑'));
  await tester.pumpAndSettle();
  return source;
}

void main() {
  testWidgets('改列名后索引跟着改名，预览、执行后结构页重读', (tester) async {
    var altered = 0;
    final source = await openEditor(tester, onAltered: () => altered++);
    expect(find.text('编辑结构：shop.posts'), findsOneWidget);
    final loadsBefore = source.structureLoads;

    await tester.enterText(find.byKey(const ValueKey('column-name-1')), 'headline');
    await tester.enterText(find.byKey(const ValueKey('column-comment-1')), '标题');
    await settle(tester);

    source.plan = const AlterPlan(
      statements: ['ALTER TABLE `shop`.`posts`\n  CHANGE COLUMN `title` `headline` varchar(100) NOT NULL DEFAULT \'\''],
      dangers: ['删除列 body：这一列的数据会永久丢失'],
      notes: ['MySQL 的 DDL 会隐式提交当前事务，执行后不能回滚。'],
    );
    await tester.tap(find.text('预览 DDL'));
    await settle(tester);

    final draft = source.previews.single;
    final title = draft.columns[1];
    expect(title.originalName, 'title');
    expect(title.name, 'headline');
    expect(title.comment, '标题');
    expect(title.default_, const DefaultValue.literal(''), reason: '空串默认值不能变成无默认值');
    expect(draft.indexes[1].parts.single.column, 'headline', reason: '索引引用的是列本身，改名跟着走');
    expect(draft.indexes[1].parts.single.prefix, 10);

    expect(find.text('确认要执行的 DDL'), findsOneWidget);
    expect(find.textContaining('CHANGE COLUMN `title` `headline`'), findsOneWidget);
    expect(find.text('删除列 body：这一列的数据会永久丢失'), findsOneWidget);
    expect(find.textContaining('隐式提交'), findsOneWidget);

    await tester.tap(find.text('我已了解风险，执行'));
    await settle(tester);
    expect(source.applied.single, source.plan.statements);
    expect(find.text('确认要执行的 DDL'), findsNothing);
    expect(find.text('编辑结构：shop.posts'), findsNothing);
    expect(source.structureLoads, loadsBefore + 1, reason: '执行后结构页重读');
    expect(altered, 1, reason: '执行成功要通知外面刷新补全目录');
  });

  testWidgets('删列会把它从索引里拿掉，加列默认可空、默认 NULL', (tester) async {
    final source = await openEditor(tester);

    await tester.tap(find.byKey(const ValueKey('column-delete-1')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('add-column')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('column-name-2')), 'summary');
    await settle(tester);

    await tester.tap(find.text('预览 DDL'));
    await settle(tester);
    final draft = source.previews.single;
    expect([for (final c in draft.columns) c.name], ['id', 'body', 'summary']);
    final added = draft.columns[2];
    expect(added.originalName, isNull);
    expect(added.nullable, isTrue);
    expect(added.default_, const DefaultValue.null_());
    expect(draft.indexes[1].parts, isEmpty, reason: '拿空的索引留给 core 报错，界面不偷偷删索引');
  });

  testWidgets('预览失败时显示 core 给的原因，不弹预览', (tester) async {
    final source = await openEditor(tester);
    source.previewError = Exception('索引 idx_title 没有列');

    await tester.tap(find.text('预览 DDL'));
    await settle(tester);
    expect(find.textContaining('索引 idx_title 没有列'), findsOneWidget);
    expect(find.text('确认要执行的 DDL'), findsNothing);
  });

  testWidgets('执行失败时预览留着并显示第几条失败', (tester) async {
    var altered = 0;
    final source = await openEditor(tester, onAltered: () => altered++);
    source.applyError = Exception('第 2 条（共 2 条）执行失败：…；前 1 条已经生效，不会回滚');

    await tester.tap(find.text('预览 DDL'));
    await settle(tester);
    expect(find.text('执行'), findsOneWidget, reason: '没有危险操作时按钮不带警告');
    await tester.tap(find.text('执行'));
    await settle(tester);
    expect(find.textContaining('前 1 条已经生效'), findsOneWidget);
    expect(find.text('确认要执行的 DDL'), findsOneWidget);
    expect(source.applied, isEmpty);
    expect(altered, 0, reason: '没执行成功不通知');
  });

  testWidgets('前缀长度不是数字时直接报错，不当成没填', (tester) async {
    final source = await openEditor(tester);
    // 结构页自己也有一个「索引 2」标签，编辑器的在上层，是最后一个
    await tester.tap(find.text('索引 2').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.widgetWithText(TextField, '10'), 'abc');
    await settle(tester);

    await tester.tap(find.text('预览 DDL'));
    await settle(tester);
    expect(find.textContaining('前缀长度「abc」不是数字'), findsOneWidget);
    expect(source.previews, isEmpty);
  });

  testWidgets('锁住的列只能改名和删除', (tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final structure = postsStructure();
    final source = FakeSchemaSource.simple()..structures['posts'] = structure;
    final normal = source.draftOf(structure);
    source.draft = TableDraft(
      columns: [
        normal.columns[0],
        ColumnDraft(
          originalName: 'title',
          name: 'title',
          columnType: 'varchar(100)',
          nullable: false,
          default_: const DefaultValue.literal(''),
          autoIncrement: false,
          comment: '',
          locked: '列属性「VIRTUAL GENERATED」没法原样重建',
        ),
        normal.columns[2],
      ],
      indexes: normal.indexes,
      foreignKeys: normal.foreignKeys,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTableStructure(context, source: source, database: 'shop', table: 'posts'),
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('column-locked-1')), findsOneWidget);
    final type = tester.widget<TextField>(find.byKey(const ValueKey('column-type-1')));
    expect(type.enabled, isFalse);
    final name = tester.widget<TextField>(find.byKey(const ValueKey('column-name-1')));
    expect(name.enabled, isTrue);
    final otherType = tester.widget<TextField>(find.byKey(const ValueKey('column-type-2')));
    expect(otherType.enabled, isTrue);
  });
}
