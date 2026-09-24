// 筛选条和筛选对话框的 widget 测试。SQL 生成和转义由 cdata-core 的测试保证，
// 这里只管界面：条件编辑得对不对、返回给调用方的是什么。

import 'package:cdata_flutter/filter_panel.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef FilterResult = ({List<FilterCondition> conditions, bool matchAll});

/// 只有一层条件时，把返回的分组摊平，断言写起来直接
FilterResult? flatten(FilterGroup? group) {
  if (group == null) return null;
  final conditions = <FilterCondition>[];
  for (final item in group.items) {
    switch (item) {
      case FilterItem_Condition(:final field0):
        conditions.add(field0);
      case FilterItem_Group():
        fail('这条测试没有建分组');
    }
  }
  return (conditions: conditions, matchAll: group.matchAll);
}

/// 放一个按钮打开对话框，把返回值（摊平成一层）记下来
Future<List<FilterResult?>> pumpDialog(
  WidgetTester tester, {
  List<FilterCondition> initial = const [],
  bool matchAll = true,
}) async {
  final results = <FilterResult?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final group = await showFilterGroupDialog(
                context,
                columns: const ['id', 'name', 'note'],
                initial: FilterGroup(
                  matchAll: matchAll,
                  items: [for (final condition in initial) FilterItem.condition(condition)],
                ),
              );
              results.add(flatten(group));
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return results;
}

/// 从下拉框里选一项。菜单打开后同一个文字会出现两次，取最后一个（菜单里的那个）
Future<void> choose(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  // 运算符有 12 个，菜单放不下时靠后的项在可视区外，要先滚过去
  await tester.ensureVisible(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('第一次打开给一条空条件，编辑后应用', (tester) async {
    final results = await pumpDialog(tester);

    await choose(tester, 'filter-column-0', 'name');
    await choose(tester, 'filter-op-0', '包含');
    await tester.enterText(find.byKey(const ValueKey('filter-value-0')), '张');
    // 编辑框光标会闪，不能 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    final result = results.single!;
    expect(result.matchAll, isTrue);
    expect(result.conditions, [
      const FilterCondition(column: 'name', op: FilterOp.contains, value: '张'),
    ]);
  });

  testWidgets('多条件 + 满足任一，IS NULL 不带值', (tester) async {
    final results = await pumpDialog(tester, initial: const [
      FilterCondition(column: 'id', op: FilterOp.gt, value: '10'),
    ]);

    await tester.tap(find.text('添加条件'));
    await tester.pumpAndSettle();
    await choose(tester, 'filter-column-1', 'note');
    await tester.enterText(find.byKey(const ValueKey('filter-value-1')), '残留的输入');
    await tester.pump(const Duration(milliseconds: 100));
    await choose(tester, 'filter-op-1', '为 NULL');
    await choose(tester, 'filter-match', '满足任一条件');

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    final result = results.single!;
    expect(result.matchAll, isFalse);
    expect(result.conditions, [
      const FilterCondition(column: 'id', op: FilterOp.gt, value: '10'),
      const FilterCondition(column: 'note', op: FilterOp.isNull, value: ''),
    ]);
  });

  testWidgets('删光条件再应用就是清除筛选', (tester) async {
    final results = await pumpDialog(tester, initial: const [
      FilterCondition(column: 'id', op: FilterOp.eq, value: '1'),
    ]);

    await tester.tap(find.byKey(const ValueKey('filter-remove-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(results.single!.conditions, isEmpty);
  });

  testWidgets('取消返回 null，调用方什么都不改', (tester) async {
    final results = await pumpDialog(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });

  testWidgets('条件里的列不在当前列里时照样显示，不崩', (tester) async {
    await pumpDialog(tester, initial: const [
      FilterCondition(column: 'gone', op: FilterOp.eq, value: 'x'),
    ]);
    expect(find.text('gone'), findsOneWidget);
  });

  testWidgets('筛选条显示条件摘要，有条件才给清除', (tester) async {
    var cleared = false;
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: FilterBar(
          filter: const FilterGroup(matchAll: true, items: [
            FilterItem.condition(FilterCondition(column: 'amount', op: FilterOp.gtEq, value: '10')),
            FilterItem.condition(FilterCondition(column: 'note', op: FilterOp.isNotNull, value: '')),
          ]),
          onEdit: () {},
          onClear: () => cleared = true,
        ),
      ),
    ));

    expect(find.text('amount ≥ 10 且 note 不为 NULL'), findsOneWidget);
    await tester.tap(find.text('清除'));
    expect(cleared, isTrue);

    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: FilterBar(filter: const FilterGroup(matchAll: true, items: []), onEdit: () {}, onClear: () {}),
      ),
    ));
    expect(find.text('未筛选'), findsOneWidget);
    expect(find.text('清除'), findsNothing);
  });

  testWidgets('IN 的值一行一个，原样交给 core；NOT IN 提示 NULL 行不会命中', (tester) async {
    // 运算符菜单是懒建的，窗口太矮时最后几项根本不在树里，ensureVisible 也找不到
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final results = await pumpDialog(tester);

    await choose(tester, 'filter-op-0', '不属于列表');
    expect(find.textContaining('该列为 NULL 的行不会命中'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('filter-value-0')), '1\n2,3\n');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    // 怎么切行、空行和 NULL 怎么处理都是 core 的事，界面不动原文
    expect(results.single!.conditions, [
      const FilterCondition(column: 'id', op: FilterOp.notIn, value: '1\n2,3\n'),
    ]);
  });

  /// 打开分组筛选对话框，返回值记下来
  Future<List<FilterGroup?>> pumpGroupDialog(WidgetTester tester, FilterGroup initial) async {
    final results = <FilterGroup?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                results.add(await showFilterGroupDialog(
                  context,
                  columns: const ['id', 'name', 'note'],
                  initial: initial,
                ));
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('分组：拼出 (A 且 B) 或 (C 且 D)', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final results = await pumpGroupDialog(tester, const FilterGroup(matchAll: true, items: []));

    await choose(tester, 'filter-match', '满足任一条件');
    // 默认给的那条删掉，换成两个分组
    await tester.tap(find.byKey(const ValueKey('filter-remove-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-add-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-add-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-add-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-add-1')));
    await tester.pumpAndSettle();

    // 新分组默认和外层相反，外层「任一」时组里是「全部」
    await tester.enterText(find.byKey(const ValueKey('filter-value-0.0')), '1');
    await tester.enterText(find.byKey(const ValueKey('filter-value-0.1')), '2');
    await choose(tester, 'filter-op-1.0', '属于列表');
    await tester.enterText(find.byKey(const ValueKey('filter-value-1.0')), '5\n6');
    await choose(tester, 'filter-column-1.1', 'name');
    await tester.enterText(find.byKey(const ValueKey('filter-value-1.1')), 'x');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    final result = results.single!;
    // FRB 生成的类比较 List 用的是引用相等，按描述比
    expect(describeFilterGroup(result), '(id = 1 且 id = 2) 或 (id 属于列表 (5, 6) 且 name = x)');
    expect(result.items, everyElement(isA<FilterItem_Group>()));
  });

  testWidgets('分组里最后一条删掉，分组跟着删；初始的嵌套条件照样显示', (tester) async {
    await pumpGroupDialog(
      tester,
      const FilterGroup(matchAll: true, items: [
        FilterItem.condition(FilterCondition(column: 'id', op: FilterOp.eq, value: '1')),
        FilterItem.group(FilterGroup(matchAll: false, items: [
          FilterItem.condition(FilterCondition(column: 'note', op: FilterOp.isNull, value: '')),
        ])),
      ]),
    );
    expect(find.byKey(const ValueKey('filter-match-1')), findsOneWidget);
    expect(find.text('note'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filter-remove-1.0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-match-1')), findsNothing, reason: '空分组 core 不收，界面里也不留');
    expect(find.byKey(const ValueKey('filter-value-0')), findsOneWidget);
  });

  testWidgets('筛选条显示分组摘要', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: FilterBar(
          filter: const FilterGroup(matchAll: false, items: [
            FilterItem.group(FilterGroup(matchAll: true, items: [
              FilterItem.condition(FilterCondition(column: 'a', op: FilterOp.eq, value: '1')),
              FilterItem.condition(FilterCondition(column: 'b', op: FilterOp.in_, value: '2\r\n3\r\n')),
            ])),
            FilterItem.condition(FilterCondition(column: 'c', op: FilterOp.isNull, value: '')),
          ]),
          onEdit: () {},
          onClear: () {},
        ),
      ),
    ));
    expect(find.text('(a = 1 且 b 属于列表 (2, 3)) 或 c 为 NULL'), findsOneWidget);
    expect(find.text('清除'), findsOneWidget);
  });
}
