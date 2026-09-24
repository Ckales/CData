// 筛选条和筛选对话框的 widget 测试。SQL 生成和转义由 cdata-core 的测试保证，
// 这里只管界面：条件编辑得对不对、返回给调用方的是什么。

import 'package:cdata_flutter/filter_panel.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef FilterResult = ({List<FilterCondition> conditions, bool matchAll});

/// 放一个按钮打开对话框，把返回值记下来
Future<List<FilterResult?>> pumpDialog(
  WidgetTester tester, {
  List<FilterCondition> initial = const [],
  bool matchAll = true,
}) async {
  final results = <FilterResult?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              results.add(await showFilterDialog(
                context,
                columns: const ['id', 'name', 'note'],
                initial: initial,
                matchAll: matchAll,
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
      home: Scaffold(
        body: FilterBar(
          conditions: const [
            FilterCondition(column: 'amount', op: FilterOp.gtEq, value: '10'),
            FilterCondition(column: 'note', op: FilterOp.isNotNull, value: ''),
          ],
          matchAll: true,
          onEdit: () {},
          onClear: () => cleared = true,
        ),
      ),
    ));

    expect(find.text('amount ≥ 10 且 note 不为 NULL'), findsOneWidget);
    await tester.tap(find.text('清除'));
    expect(cleared, isTrue);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilterBar(conditions: const [], matchAll: true, onEdit: () {}, onClear: () {}),
      ),
    ));
    expect(find.text('未筛选'), findsOneWidget);
    expect(find.text('清除'), findsNothing);
  });
}
