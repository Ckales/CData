// 表结构编辑器的 widget 测试。DDL 怎么生成、危险操作怎么判定由 cdata-core 的测试保证，
// 这里只验证界面把改动正确拼成草稿、预览和执行的流程、各种提示显示出来。

import 'package:cdata_flutter/src/rust/api/schema.dart';
import 'package:cdata_flutter/structure_editor.dart';
import 'package:cdata_flutter/structure_view.dart';
import 'package:cdata_flutter/theme.dart';
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
    tableCharset: 'utf8mb4',
    engine: 'InnoDB',
    tableComment: '文章',
    autoIncrement: BigInt.from(42),
    checks: const [CheckDef(name: 'chk_title', expression: "(`title` <> '')", enforced: true)],
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
    theme: appTheme(Brightness.light),
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

  testWidgets('没设 ON UPDATE 的列提示「无」，不写成像值的例子', (tester) async {
    await openEditor(tester);
    expect(find.text('无'), findsWidgets);
    expect(find.text('CURRENT_TIMESTAMP'), findsNothing, reason: '没设 ON UPDATE 的列不能显示得像设了一样');
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
      checks: normal.checks,
      options: normal.options,
    );

    await tester.pumpWidget(MaterialApp(
    theme: appTheme(Brightness.light),
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

  testWidgets('已有的 CHECK 只能删，表选项和新 CHECK 拼进草稿', (tester) async {
    final source = await openEditor(tester);

    await tester.tap(find.text('CHECK 1').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final existing = tester.widget<TextField>(find.byKey(const ValueKey('check-expression-0')));
    expect(existing.enabled, isFalse, reason: '读到的表达式没法原样重建，不许改');
    await tester.tap(find.byKey(const ValueKey('check-delete-0')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('add-check')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('check-name-0')), 'chk_body');
    await tester.enterText(find.byKey(const ValueKey('check-expression-0')), "body <> ''");
    await settle(tester);

    await tester.tap(find.text('表选项'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('当前 42，留空不改'), findsOneWidget, reason: '自增值只当提示，不照抄进草稿');
    await tester.enterText(find.byKey(const ValueKey('option-comment')), '文章表');
    await tester.enterText(find.byKey(const ValueKey('option-collation')), 'utf8mb4_bin');
    await tester.tap(find.byKey(const ValueKey('option-convert')));
    await settle(tester);

    await tester.tap(find.text('预览 DDL'));
    await settle(tester);
    final draft = source.previews.single;
    expect(draft.checks.single.originalName, isNull);
    expect(draft.checks.single.name, 'chk_body');
    expect(draft.checks.single.expression, "body <> ''");
    expect(draft.options.comment, '文章表');
    expect(draft.options.engine, 'InnoDB');
    expect(draft.options.charset, 'utf8mb4');
    expect(draft.options.collation, 'utf8mb4_bin');
    expect(draft.options.convertCharset, isTrue);
    expect(draft.options.autoIncrement, isNull);
  });

  testWidgets('AUTO_INCREMENT 不是数字时直接报错', (tester) async {
    final source = await openEditor(tester);
    await tester.tap(find.text('表选项'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byKey(const ValueKey('option-auto-increment')), '1e3');
    await settle(tester);
    await tester.tap(find.text('预览 DDL'));
    await settle(tester);
    expect(find.textContaining('AUTO_INCREMENT「1e3」不是正整数'), findsOneWidget);
    expect(source.previews, isEmpty);
  });

  Future<(FakeSchemaSource, Future<String?>)> openCreator(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final source = FakeSchemaSource.simple();
    late Future<String?> result;
    await tester.pumpWidget(MaterialApp(
    theme: appTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showTableCreator(context, source: source, database: 'shop'),
            child: const Text('新建'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    return (source, result);
  }

  testWidgets('新建表：起始草稿的主键指向 id，预览、执行后返回表名', (tester) async {
    final (source, result) = await openCreator(tester);
    expect(find.text('新建表：shop.'), findsOneWidget);
    expect(find.byKey(const ValueKey('option-convert')), findsNothing, reason: '新建表没有已有列可转换');

    await tester.enterText(find.byKey(const ValueKey('table-name')), 'tags');
    await tester.tap(find.byKey(const ValueKey('add-column')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('column-name-1')), 'label');
    await settle(tester);

    source.plan = const AlterPlan(
      statements: ['CREATE TABLE `shop`.`tags` (…)'],
      dangers: [],
      notes: ['CREATE TABLE 会隐式提交当前事务。'],
    );
    await tester.tap(find.text('预览 DDL'));
    await settle(tester);

    final (table, draft) = source.createPreviews.single;
    expect(table, 'tags');
    expect(source.previews, isEmpty, reason: '新建表不走改表的预览');
    expect([for (final c in draft.columns) c.name], ['id', 'label']);
    expect(draft.columns.every((c) => c.originalName == null), isTrue);
    expect(draft.indexes.single.parts.single.column, 'id', reason: '起始主键要认得出 id 列，不能变成表达式');
    expect(draft.options.engine, 'InnoDB');
    expect(draft.options.charset, isNull, reason: '不填就跟着库走');

    expect(find.textContaining('CREATE TABLE `shop`.`tags`'), findsOneWidget);
    await tester.tap(find.text('执行'));
    await settle(tester);
    expect(source.created.single, ('tags', source.plan.statements));
    expect(await result, 'tags');
  });

  testWidgets('新建表：表名已存在时显示 core 的原因；取消返回 null', (tester) async {
    final (source, result) = await openCreator(tester);
    source.previewError = Exception('shop 里已经有叫 users 的表，换个名字');
    await tester.enterText(find.byKey(const ValueKey('table-name')), 'users');
    await settle(tester);
    await tester.tap(find.text('预览 DDL'));
    await settle(tester);
    expect(find.textContaining('已经有叫 users 的表'), findsOneWidget);
    expect(find.text('确认要执行的 DDL'), findsNothing);

    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(await result, isNull);
    expect(source.created, isEmpty);
  });
}
