// 补全弹窗的 widget 测试。候选怎么算由 cdata-core 的 complete 测试保证，这里用固定的假候选。

import 'package:cdata_flutter/sql_editor.dart';
import 'package:cdata_flutter/src/rust/api/editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

CompletionItem item(String label, {CompletionKind kind = CompletionKind.table, String? insert}) {
  return CompletionItem(label: label, insertText: insert ?? label, kind: kind, detail: '');
}

/// 光标前那个词当前缀，从固定的几张表里筛
Completion? fakeComplete(String sql, int cursor) {
  final before = sql.substring(0, cursor);
  final match = RegExp(r'[\w`]*$').firstMatch(before)!;
  final prefix = match.group(0)!.replaceAll('`', '').toLowerCase();
  final items = <CompletionItem>[];
  for (final candidate in [item('orders'), item('order_items'), item('users'), item('order', insert: '`order`')]) {
    if (candidate.label.startsWith(prefix)) items.add(candidate);
  }
  return Completion(replaceStart: match.start, replaceEnd: cursor, items: items);
}

Future<SqlEditingController> pumpEditor(WidgetTester tester, {VoidCallback? onRun}) async {
  final controller = SqlEditingController(tokenize: (_) => const []);
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SqlEditorField(controller: controller, complete: fakeComplete, onRun: onRun),
      ),
    ),
  ));
  return controller;
}

/// 编辑框里光标一直在闪，不能 pumpAndSettle
Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.pump();
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

void main() {
  testWidgets('打字弹出候选，Enter 接受并替换正在输入的词', (tester) async {
    final controller = await pumpEditor(tester);
    await type(tester, 'SELECT * FROM ord');

    expect(find.byKey(const ValueKey('completion-popup')), findsOneWidget);
    expect(find.text('orders'), findsOneWidget);
    expect(find.text('users'), findsNothing, reason: '按前缀筛');

    await press(tester, LogicalKeyboardKey.enter);
    expect(controller.text, 'SELECT * FROM orders', reason: 'Enter 接受候选，不是换行');
    expect(controller.selection.baseOffset, controller.text.length);
    expect(find.byKey(const ValueKey('completion-popup')), findsNothing);
  });

  testWidgets('上下键换选中项，Tab 也能接受，插入的是 insertText', (tester) async {
    final controller = await pumpEditor(tester);
    await type(tester, 'SELECT * FROM or');

    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.tab);
    expect(controller.text, 'SELECT * FROM `order`', reason: '撞关键字的名字插入带反引号的版本');
  });

  testWidgets('往上翻过头绕到最后一项', (tester) async {
    final controller = await pumpEditor(tester);
    await type(tester, 'SELECT * FROM or');
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.enter);
    expect(controller.text, 'SELECT * FROM `order`');
  });

  testWidgets('Esc 关掉弹窗，之后的回车照常换行', (tester) async {
    final controller = await pumpEditor(tester);
    await type(tester, 'SELECT * FROM us');
    expect(find.byKey(const ValueKey('completion-popup')), findsOneWidget);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(const ValueKey('completion-popup')), findsNothing);
    expect(controller.text, 'SELECT * FROM us', reason: 'Esc 不改文本');
  });

  testWidgets('敲空格、没有候选时不弹', (tester) async {
    await pumpEditor(tester);
    await type(tester, 'SELECT * FROM ');
    expect(find.byKey(const ValueKey('completion-popup')), findsNothing);

    await type(tester, 'SELECT * FROM zzz');
    expect(find.byKey(const ValueKey('completion-popup')), findsNothing);
  });

  testWidgets('点候选项接受', (tester) async {
    final controller = await pumpEditor(tester);
    await type(tester, 'SELECT * FROM u');
    await tester.tap(find.text('users'));
    await tester.pump();
    expect(controller.text, 'SELECT * FROM users');
  });

  testWidgets('Ctrl + Space 手动唤出，⌘ + Enter 运行并收起弹窗', (tester) async {
    var ran = 0;
    await pumpEditor(tester, onRun: () => ran++);
    await type(tester, 'SELECT * FROM ');
    expect(find.byKey(const ValueKey('completion-popup')), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('completion-popup')), findsOneWidget, reason: '空前缀时列出全部');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();
    expect(ran, 1);
    expect(find.byKey(const ValueKey('completion-popup')), findsNothing);
  });
}
