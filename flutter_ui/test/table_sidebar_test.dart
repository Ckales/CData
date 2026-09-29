// 侧栏的 widget 测试。内存数据，不起 app、不连库。

import 'package:cdata_flutter/src/rust/api/db.dart' show ExportFormat;
import 'package:cdata_flutter/src/rust/api/schema.dart';
import 'package:cdata_flutter/table_sidebar.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<void> pumpSidebar(
  WidgetTester tester,
  FakeSchemaSource source, {
  String database = 'shop',
  void Function(String table)? onTableSelected,
  void Function(String database)? onDatabaseChanged,
  void Function(String table)? onShowStructure,
  Future<bool> Function(String? table)? onImport,
  Future<String?> Function(String database)? onCreateTable,
  void Function(String table)? onOpenInNewTab,
  void Function(String table, TableAction action)? onTableAction,
  Future<String?> Function(String suggestedName)? pickSavePath,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TableSidebar(
          source: source,
          database: database,
          onDatabaseChanged: onDatabaseChanged ?? (_) {},
          onTableSelected: onTableSelected ?? (_) {},
          onShowStructure: onShowStructure,
          onImport: onImport,
          onCreateTable: onCreateTable,
          onOpenInNewTab: onOpenInNewTab,
          onTableAction: onTableAction,
          pickSavePath: pickSavePath,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('列出表并统计数量', (tester) async {
    await pumpSidebar(tester, FakeSchemaSource.simple());

    expect(find.text('orders'), findsOneWidget);
    expect(find.text('users'), findsOneWidget);
    expect(find.text('4 张表'), findsOneWidget);
  });

  testWidgets('选库：弹层挂在按钮下面，过滤后回车选第一个，Esc 关掉', (tester) async {
    final source = FakeSchemaSource(
      dbs: [for (var i = 0; i < 60; i++) 'db_$i', 'shop'],
      tablesByDb: {'shop': []},
    );
    String? switchedTo;
    await pumpSidebar(tester, source, onDatabaseChanged: (database) => switchedTo = database);

    final button = tester.getRect(find.byKey(const ValueKey('database-picker')));
    await tester.tap(find.byKey(const ValueKey('database-picker')));
    await tester.pumpAndSettle();
    final filter = find.byKey(const ValueKey('database-picker-filter'));
    expect(tester.getTopLeft(filter).dy, greaterThan(button.bottom), reason: '库多的时候也不能被推到窗口顶上');
    expect(find.byIcon(Icons.check), findsOneWidget, reason: '打开时滚到当前库，打勾');

    await tester.enterText(filter, 'B_4');
    await tester.pump();
    expect(find.text('db_4'), findsOneWidget, reason: '不分大小写');
    expect(find.text('db_40'), findsOneWidget);
    expect(find.text('db_1'), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(switchedTo, 'db_4');
    expect(filter, findsNothing);

    await tester.tap(find.byKey(const ValueKey('database-picker')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(filter, findsNothing);
  });

  testWidgets('估算行数标 ~，视图不标', (tester) async {
    await pumpSidebar(tester, FakeSchemaSource.simple());

    // InnoDB 的行数是估算值，不能显示成精确数字
    expect(find.text('~1200'), findsOneWidget);
    // 视图没有行数，也不该显示 ~0
    expect(find.text('~0'), findsNothing);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
  });

  testWidgets('过滤表名', (tester) async {
    await pumpSidebar(tester, FakeSchemaSource.simple());

    await tester.enterText(find.byType(TextField), 'order');
    await tester.pumpAndSettle();

    expect(find.text('orders'), findsOneWidget);
    expect(find.text('order_items'), findsOneWidget);
    expect(find.text('users'), findsNothing);
    expect(find.text('2 / 4 张表'), findsOneWidget);
  });

  testWidgets('点表回调表名', (tester) async {
    String? tapped;
    await pumpSidebar(
      tester,
      FakeSchemaSource.simple(),
      onTableSelected: (table) => tapped = table,
    );

    await tester.tap(find.text('order_items'));
    await tester.pumpAndSettle();

    expect(tapped, 'order_items');
  });

  testWidgets('导入只有一个入口；表传目标表，视图和空库不传目标表', (tester) async {
    final targets = <String?>[];
    await pumpSidebar(tester, FakeSchemaSource.simple(), onImport: (table) async {
      targets.add(table);
      return true;
    });

    await tester.tap(find.text('users'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('导入…'), findsOneWidget);
    expect(find.text('导入 CSV…'), findsNothing);
    expect(find.text('导入 SQL…'), findsNothing);
    await tester.tap(find.text('导入…'));
    await tester.pumpAndSettle();
    expect(targets, ['users']);

    await tester.tap(find.text('v_daily'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入…'));
    await tester.pumpAndSettle();
    expect(targets, ['users', null]);

    await pumpSidebar(tester, FakeSchemaSource(dbs: ['shop'], tablesByDb: {'shop': []}), onImport: (table) async {
      targets.add(table);
      return false;
    });
    await tester.tap(find.byType(TableSidebar), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('导入…'), findsOneWidget);
    await tester.tap(find.text('导入…'));
    await tester.pumpAndSettle();
    expect(targets, ['users', null, null]);

    await pumpSidebar(tester, FakeSchemaSource.simple());
    await tester.tap(find.text('users'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('导入…'), findsNothing);
  });

  testWidgets('右键「新建表…」把当前库交给调用方，建好后重读清单并选中，不顺带跑查询', (tester) async {
    final source = FakeSchemaSource.simple();
    String? createdIn;
    String? browsed;
    await pumpSidebar(
      tester,
      source,
      onTableSelected: (table) => browsed = table,
      onCreateTable: (database) async {
        createdIn = database;
        source.tablesByDb['shop']!.add(TableInfo(name: 'tags', estimatedRows: BigInt.zero, isView: false));
        return 'tags';
      },
    );

    await tester.tap(find.text('users'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建表…'));
    await tester.pumpAndSettle();
    expect(createdIn, 'shop');
    expect(find.text('tags'), findsOneWidget, reason: '建好之后清单要重读');
    expect(find.text('5 张表'), findsOneWidget);
    expect(browsed, isNull);
  });

  testWidgets('取消新建不重读；空库在空白处右键也能新建；不给回调就没有这一项', (tester) async {
    var loads = 0;
    final source = FakeSchemaSource.simple();
    await pumpSidebar(tester, source, database: 'analytics', onCreateTable: (database) async {
      loads++;
      return null;
    });
    await tester.tap(find.byKey(const ValueKey('sidebar-blank')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建表…'));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(find.text('0 张表'), findsOneWidget);

    await pumpSidebar(tester, FakeSchemaSource.simple());
    await tester.tap(find.text('users'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('新建表…'), findsNothing);
  });

  testWidgets('空库显示 0 张表而不是报错', (tester) async {
    await pumpSidebar(tester, FakeSchemaSource.simple(), database: 'analytics');

    expect(find.text('0 张表'), findsOneWidget);
  });

  testWidgets('右键表名弹菜单，可以看结构也可以浏览', (tester) async {
    String? structureOf;
    String? browsed;
    await pumpSidebar(
      tester,
      FakeSchemaSource.simple(),
      onShowStructure: (table) => structureOf = table,
      onTableSelected: (table) => browsed = table,
    );

    await tester.tap(find.text('users'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看结构'));
    await tester.pumpAndSettle();
    expect(structureOf, 'users');
    expect(browsed, isNull, reason: '看结构不该顺带跑查询');

    await tester.tap(find.text('orders'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('浏览数据'));
    await tester.pumpAndSettle();
    expect(browsed, 'orders');
  });

  group('表的右键菜单', () {
    /// DDL 确认框 860×560，默认的测试窗口放不下
    void bigWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<void> menu(WidgetTester tester, String table, String item) async {
      await tester.tap(find.text(table), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    testWidgets('重命名：填新名字 → 确认 DDL → 执行，清单换成新名字并通知外面', (tester) async {
      bigWindow(tester);
      final source = FakeSchemaSource.simple()
        ..plan = const AlterPlan(statements: ['RENAME TABLE `shop`.`users` TO `shop`.`members`'], dangers: [], notes: []);
      final actions = <(String, TableAction)>[];
      await pumpSidebar(tester, source, onTableAction: (table, action) => actions.add((table, action)));

      await menu(tester, 'users', '重命名…');
      await tester.enterText(find.byKey(const ValueKey('table-name-field')), 'members');
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      expect(find.text('RENAME TABLE `shop`.`users` TO `shop`.`members`'), findsOneWidget);

      await tester.tap(find.text('执行'));
      await tester.pumpAndSettle();
      expect(source.actionsApplied.single.$3, ['RENAME TABLE `shop`.`users` TO `shop`.`members`']);
      expect(actions.single, ('users', const TableAction.rename(newName: 'members')));
      expect(find.text('members'), findsOneWidget);
      expect(find.text('users'), findsNothing);
    });

    testWidgets('删除要在确认框里点危险按钮，取消就不执行', (tester) async {
      bigWindow(tester);
      final source = FakeSchemaSource.simple()
        ..plan = const AlterPlan(
          statements: ['DROP TABLE `shop`.`orders`'],
          dangers: ['删除表 orders 和里面的全部数据，不能撤销'],
          notes: [],
        );
      await pumpSidebar(tester, source);

      await menu(tester, 'orders', '删除…');
      expect(find.text('删除表 orders 和里面的全部数据，不能撤销'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(source.actionsApplied, isEmpty);

      await menu(tester, 'orders', '删除…');
      await tester.tap(find.text('我已了解风险，执行'));
      await tester.pumpAndSettle();
      expect(source.actionsApplied.single.$2, const TableAction.drop());
      expect(find.text('orders'), findsNothing);
    });

    testWidgets('复制表默认叫 _copy、连数据一起复制，可以取消勾选', (tester) async {
      bigWindow(tester);
      final source = FakeSchemaSource.simple();
      await pumpSidebar(tester, source);

      await menu(tester, 'orders', '复制表…');
      expect(find.widgetWithText(TextField, 'orders_copy'), findsOneWidget);
      await tester.tap(find.text('同时复制数据'));
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      expect(source.actionPreviews.single.$2, const TableAction.duplicate(newName: 'orders_copy', withData: false));
    });

    testWidgets('视图不给复制表、复制 INSERT、统计行数、表操作', (tester) async {
      await pumpSidebar(tester, FakeSchemaSource.simple());
      await tester.tap(find.text('v_daily'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('重命名…'), findsOneWidget);
      expect(find.text('删除…'), findsOneWidget);
      expect(find.text('复制表…'), findsNothing);
      expect(find.text('复制 INSERT 语句'), findsNothing);
      expect(find.text('统计行数'), findsNothing);
      expect(find.text('表操作'), findsNothing);
    });

    testWidgets('复制名称、INSERT 语句放进剪贴板', (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpSidebar(tester, FakeSchemaSource.simple());

      await menu(tester, 'orders', '复制名称');
      expect(clipboard, 'orders');
      await menu(tester, 'orders', '复制 INSERT 语句');
      expect(clipboard, 'INSERT INTO `orders` (`id`)\nVALUES\n\t(?);');
    });

    testWidgets('统计行数显示精确值；表操作里的优化表显示 MySQL 的消息', (tester) async {
      final source = FakeSchemaSource.simple();
      await pumpSidebar(tester, source);

      await menu(tester, 'orders', '统计行数');
      expect(find.text('共 1234 行（COUNT(*) 精确值）'), findsOneWidget);
      await tester.tap(find.text('好'));
      await tester.pumpAndSettle();

      await menu(tester, 'orders', '表操作');
      await tester.tap(find.text('优化表'));
      await tester.pumpAndSettle();
      expect(source.maintenanceRuns.single, ('orders', Maintenance.optimize));
      expect(find.text('status：OK'), findsOneWidget);
    });

    testWidgets('表操作里的清空表走确认框', (tester) async {
      bigWindow(tester);
      final source = FakeSchemaSource.simple();
      await pumpSidebar(tester, source);

      await menu(tester, 'orders', '表操作');
      await tester.tap(find.text('清空表…'));
      await tester.pumpAndSettle();
      expect(source.actionPreviews.single.$2, const TableAction.truncate());
      expect(find.text('确认要执行的 DDL'), findsOneWidget);
    });

    testWidgets('导出整张表：选格式和保存位置后交给 core，完成后说写了几行', (tester) async {
      final source = FakeSchemaSource.simple();
      String? suggested;
      await pumpSidebar(
        tester,
        source,
        pickSavePath: (name) async {
          suggested = name;
          return '/tmp/orders.sql';
        },
      );

      await menu(tester, 'orders', '导出…');
      expect(find.text('整张表（不受行数上限限制）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('export-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SQL INSERT').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出…'));
      await tester.pumpAndSettle();

      expect(suggested, 'orders.sql');
      expect(source.tableExports.single.$1, 'orders');
      expect(source.tableExports.single.$2, '/tmp/orders.sql');
      expect(source.tableExports.single.$3.format, ExportFormat.sqlInsert);
      expect(find.textContaining('5000 行'), findsOneWidget);
    });

    testWidgets('导出失败显示原因，取消保存就不导出', (tester) async {
      final source = FakeSchemaSource.simple()..exportError = Exception('磁盘满了');
      String? path;
      await pumpSidebar(tester, source, pickSavePath: (_) async => path);

      await menu(tester, 'orders', '导出…');
      await tester.tap(find.text('导出…'));
      await tester.pumpAndSettle();
      expect(source.tableExports, isEmpty, reason: '保存位置取消了');

      path = '/tmp/orders.csv';
      await menu(tester, 'orders', '导出…');
      await tester.tap(find.text('导出…'));
      await tester.pumpAndSettle();
      expect(find.textContaining('磁盘满了'), findsOneWidget);
    });

    testWidgets('新建库：默认用服务器的字符集和排序规则，换字符集排序规则跟着换，建好后切过去', (tester) async {
      bigWindow(tester);
      final source = FakeSchemaSource.simple();
      String? switchedTo;
      await pumpSidebar(tester, source, onDatabaseChanged: (database) => switchedTo = database);

      await menu(tester, 'orders', '新建数据库…');
      expect(find.text('utf8mb4_general_ci'), findsOneWidget, reason: '服务器默认排序规则');
      await tester.enterText(find.byKey(const ValueKey('database-name-field')), 'blog');

      await tester.tap(find.byKey(const ValueKey('database-charset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('latin1').last);
      await tester.pumpAndSettle();
      expect(find.text('latin1_swedish_ci'), findsOneWidget, reason: '换成这个字符集自己的默认排序规则');

      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      expect(find.text('CREATE DATABASE `blog` CHARACTER SET latin1 COLLATE latin1_swedish_ci'), findsOneWidget);
      await tester.tap(find.text('执行'));
      await tester.pumpAndSettle();

      expect(source.databasesCreated.single, ('blog', 'latin1', 'latin1_swedish_ci'));
      expect(switchedTo, 'blog');
    });

    testWidgets('空库的空白处右键也能新建库', (tester) async {
      await pumpSidebar(tester, FakeSchemaSource.simple(), database: 'analytics');
      await tester.tap(find.byKey(const ValueKey('sidebar-blank')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('新建数据库…'), findsOneWidget);
    });

    testWidgets('在新标签中打开把表名交给外面', (tester) async {
      String? opened;
      await pumpSidebar(tester, FakeSchemaSource.simple(), onOpenInNewTab: (table) => opened = table);
      await menu(tester, 'users', '在新标签中打开');
      expect(opened, 'users');
    });
  });
}
