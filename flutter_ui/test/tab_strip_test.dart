// 标签条拖动换位：同一条上的标签可以左右拖，标了不能拖的不参与。

import 'package:cdata_flutter/mac_widgets.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (from, to) in [(0, 1), (2, 0)]) {
    testWidgets('鼠标从标题右侧拖动 $from 到 $to，按指针落点换位', (tester) async {
      final moves = <(int, int)>[];
      await tester.pumpWidget(
        _strip(onReorder: (from, to) => moves.add((from, to))),
      );

      final start =
          tester.getTopLeft(find.byKey(ValueKey('tab-$from'))) +
          const Offset(112, 16);
      final end = tester.getCenter(find.byKey(ValueKey('tab-$to')));
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(Offset(to > from ? 20 : -20, 0));
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(moves, [(from, to)]);
    });
  }

  testWidgets('往右拖一个标签，它移动到落点位置', (tester) async {
    final moves = <(int, int)>[];
    await tester.pumpWidget(
      _strip(onReorder: (from, to) => moves.add((from, to))),
    );

    final first = tester.getCenter(find.byKey(const ValueKey('tab-0')));
    final third = tester.getCenter(find.byKey(const ValueKey('tab-2')));
    await tester.timedDragFrom(
      first,
      third - first,
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();

    expect(moves, [(0, 2)]);
  });

  testWidgets('往左拖一个标签，它插到落点标签前面', (tester) async {
    final moves = <(int, int)>[];
    await tester.pumpWidget(
      _strip(onReorder: (from, to) => moves.add((from, to))),
    );

    final third = tester.getCenter(find.byKey(const ValueKey('tab-2')));
    final first = tester.getCenter(find.byKey(const ValueKey('tab-0')));
    await tester.timedDragFrom(
      third,
      first - third,
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();

    expect(moves, [(2, 0)]);
  });

  testWidgets('标了不能拖的标签拖不动，也不能当落点', (tester) async {
    final moves = <(int, int)>[];
    await tester.pumpWidget(
      _strip(
        onReorder: (from, to) => moves.add((from, to)),
        canReorder: (index) => index < 2,
      ),
    );

    final locked = tester.getCenter(find.byKey(const ValueKey('tab-2')));
    await tester.timedDragFrom(
      locked,
      const Offset(-140, 0),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();
    expect(moves, isEmpty);

    final first = tester.getCenter(find.byKey(const ValueKey('tab-0')));
    await tester.timedDragFrom(
      first,
      locked - first,
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();
    expect(moves, isEmpty);
  });
}

Widget _strip({
  required void Function(int from, int to) onReorder,
  bool Function(int index)? canReorder,
}) {
  return MaterialApp(
    theme: appTheme(Brightness.light),
    home: Scaffold(
      body: MacTabStrip(
        tabs: const [
          MacTab(key: ValueKey('tab-0'), title: '第一个'),
          MacTab(key: ValueKey('tab-1'), title: '第二个'),
          MacTab(key: ValueKey('tab-2'), title: '第三个'),
        ],
        active: 0,
        onSelect: (_) {},
        onClose: (_) {},
        onAdd: () {},
        addTooltip: '新标签',
        onReorder: onReorder,
        canReorder: canReorder,
      ),
    ),
  );
}
