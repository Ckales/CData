// 端到端冒烟：连真库 → 查询 → 界面显示，顺便把主界面导出成 PNG。
//
// 细粒度的 UI 行为都在 test/ 下的 widget 测试里（秒级，不连库）；
// 这里只验证"整条链路接得上"，以及出一张图用来看效果。
//
// 运行：见 run_integration_tests.sh

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cdata_flutter/query_page.dart';
import 'package:cdata_flutter/result_grid.dart' show ResultGrid;
import 'package:cdata_flutter/src/rust/api/preferences.dart' show defaultPreferences;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rust_init.dart';

const _host = String.fromEnvironment('HOST');
const _password = String.fromEnvironment('PASSWORD');
const _db = String.fromEnvironment('DB');

final _boundaryKey = GlobalKey();

/// 放真实时间过去，让 FFI 的往返完成。pump 只推虚拟时钟，等不了真实 IO
Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    for (var j = 0; j < 5; j++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
  }
}

Future<void> settleUntil(WidgetTester tester, Finder finder, {int maxRounds = 20}) async {
  for (var i = 0; i < maxRounds; i++) {
    await settle(tester, rounds: 1);
    if (finder.evaluate().isNotEmpty) return;
  }
}

Future<void> savePng(String name) async {
  final boundary = _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

  final dir = Directory('build/shots');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureRustInit);

  testWidgets('连库查询并渲染，导出主界面截图', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未通过 --dart-define 提供连接信息');
      return;
    }

    // 默认 800x600 太窄，侧栏和网格挤在一起看不出效果
    tester.view.physicalSize = const Size(2800, 1700);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorSchemeSeed: Colors.indigo),
          home: QueryPage(preferences: defaultPreferences(), onPreferencesChanged: (_) {}),
        ),
      ),
    );
    await settle(tester, rounds: 2);

    // 连接栏字段顺序：主机 / 端口 / 用户 / 密码 / 数据库
    await tester.enterText(find.byType(TextField).at(3), _password);
    await tester.enterText(find.byType(TextField).at(4), _db);
    await settle(tester, rounds: 1);

    await tester.tap(find.text('运行'));
    await settleUntil(tester, find.text('用户1'));

    expect(find.text('用户1'), findsOneWidget, reason: '没查到数据');
    expect(find.text('big_rows'), findsWidgets, reason: '侧栏没列出表');

    await savePng('main');

    // 第二个标签有自己的会话，跑别的查询不影响第一个标签的结果
    await tester.tap(find.byIcon(Icons.add));
    await settle(tester, rounds: 1);
    await tester.enterText(find.byKey(const ValueKey('sql-editor')), 'SELECT id, name FROM edit_target ORDER BY id');
    await settle(tester, rounds: 1);
    await tester.tap(find.text('运行'));
    await settleUntil(tester, find.text('第二行'));
    expect(find.text('第二行'), findsOneWidget, reason: '第二个标签没查到数据');
    expect(find.text('用户1'), findsNothing, reason: '第一个标签的结果不该显示在第二个标签里');

    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await settleUntil(tester, find.text('用户1'));
    expect(find.text('用户1'), findsOneWidget, reason: '切回第一个标签，结果要还在');

    await savePng('tabs');

    // 多连接：第二个标签改连 information_schema，第一个标签的库不受影响
    await tester.tap(find.byKey(const ValueKey('tab-2')));
    await settle(tester, rounds: 1);
    await tester.enterText(find.byType(TextField).at(4), 'information_schema');
    await tester.enterText(
      find.byKey(const ValueKey('sql-editor')),
      "SELECT TABLE_NAME FROM TABLES WHERE TABLE_SCHEMA = '$_db' AND TABLE_NAME = 'big_rows'",
    );
    await tester.tap(find.text('连接'));
    final schemaRow = find.descendant(of: find.byType(ResultGrid), matching: find.text('big_rows'));
    await settleUntil(tester, schemaRow);
    expect(schemaRow, findsOneWidget, reason: '第二个标签没连上 information_schema');

    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await settleUntil(tester, find.text('用户1'));
    expect(find.text('用户1'), findsOneWidget);
    final databaseField = tester.widget<TextField>(find.byType(TextField).at(4));
    expect(databaseField.controller!.text, _db, reason: '切回第一个标签，连接栏要显示它自己的库');

    // 补全：目录是查询成功后从真库读的，候选要带上真实的表名
    await tester.enterText(find.byKey(const ValueKey('sql-editor')), 'SELECT * FROM big');
    final popupItem = find.descendant(
      of: find.byKey(const ValueKey('completion-popup')),
      matching: find.text('big_rows'),
    );
    await settleUntil(tester, popupItem);
    expect(popupItem, findsOneWidget, reason: '补全没列出真库里的表');
    await savePng('completion');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester, rounds: 1);
    final editor = tester.widget<TextField>(
      find.descendant(of: find.byKey(const ValueKey('sql-editor')), matching: find.byType(TextField)),
    );
    expect(editor.controller!.text, 'SELECT * FROM big_rows');

    // 快捷键：焦点在编辑器里也要生效
    Future<void> command(LogicalKeyboardKey key) async {
      final modifier = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(modifier);
      await settle(tester, rounds: 1);
    }

    await command(LogicalKeyboardKey.keyT);
    expect(find.byKey(const ValueKey('tab-3')), findsOneWidget, reason: '⌘T 没开新标签');
    await command(LogicalKeyboardKey.keyW);
    expect(find.byKey(const ValueKey('tab-3')), findsNothing, reason: '⌘W 没关掉当前标签');
    await command(LogicalKeyboardKey.digit1);
    await settleUntil(tester, find.text('用户1'));
    expect(find.text('用户1'), findsOneWidget, reason: '⌘1 没切回第一个标签');
  });
}
