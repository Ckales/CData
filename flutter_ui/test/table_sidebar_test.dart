// 侧栏的 widget 测试。内存数据，不起 app、不连库。

import 'package:cdata_flutter/table_sidebar.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<void> pumpSidebar(
  WidgetTester tester,
  FakeSchemaSource source, {
  String database = 'shop',
  void Function(String table)? onTableSelected,
  void Function(String database)? onDatabaseChanged,
  void Function(String table)? onShowStructure,
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
}
