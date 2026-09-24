// 端到端冒烟：连真库 → 查询 → 界面显示，顺便把主界面导出成 PNG。
//
// 细粒度的 UI 行为都在 test/ 下的 widget 测试里（秒级，不连库）；
// 这里只验证"整条链路接得上"，以及出一张图用来看效果。
//
// 运行：见 run_integration_tests.sh

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cdata_flutter/query_page.dart';
import 'package:cdata_flutter/theme.dart';
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
const _user = String.fromEnvironment('USER');
const _port = String.fromEnvironment('PORT');

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

/// 界面上显示着的错误文字，断言失败时一并打出来，不用再猜卡在哪
String shownErrors(WidgetTester tester) {
  final texts = <String>[];
  for (final widget in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
    texts.add(widget.data ?? '');
  }
  return texts.isEmpty ? '界面上没有错误信息' : '界面上的错误：${texts.join(' | ')}';
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
          // 和真 app 用同一套主题，截图才反映真实效果
          theme: appTheme(Brightness.light),
          home: QueryPage(preferences: defaultPreferences(), onPreferencesChanged: (_) {}),
        ),
      ),
    );
    await settle(tester, rounds: 2);
    await savePng('connect');

    // 连接页：填表单、连接
    Future<void> connect(String database) async {
      await tester.enterText(find.byKey(const ValueKey('conn-host')), _host);
      await tester.enterText(find.byKey(const ValueKey('conn-port')), _port);
      await tester.enterText(find.byKey(const ValueKey('conn-user')), _user);
      await tester.enterText(find.byKey(const ValueKey('conn-password')), _password);
      await tester.enterText(find.byKey(const ValueKey('conn-database')), database);
      await settle(tester, rounds: 1);
      await tester.tap(find.byKey(const ValueKey('conn-connect')));
    }

    await connect(_db);
    await settleUntil(tester, find.text('big_rows'));
    expect(find.text('big_rows'), findsWidgets, reason: '侧栏没列出表。${shownErrors(tester)}');

    // 内容模式：点侧栏的表，网格里就是这张表的数据
    await tester.tap(find.text('big_rows').first);
    await settleUntil(tester, find.text('用户1'));
    expect(find.text('用户1'), findsOneWidget, reason: '没查到数据。${shownErrors(tester)}');
    expect(find.text('$_db.big_rows'), findsOneWidget, reason: '标签标题是 库.表');
    await savePng('main');

    // 新标签沿用当前表；切到查询模式跑别的 SQL，不影响第一个标签
    await tester.tap(find.byTooltip('新标签（⌘T）'));
    await settle(tester, rounds: 2);
    await tester.tap(find.byKey(const ValueKey('mode-query')));
    await settle(tester, rounds: 1);
    await tester.enterText(find.byKey(const ValueKey('sql-editor')), 'SELECT id, name FROM edit_target ORDER BY id');
    await settle(tester, rounds: 1);
    await tester.tap(find.text('运行'));
    await settleUntil(tester, find.text('第二行'));
    expect(find.text('第二行'), findsOneWidget, reason: '查询模式没查到数据。${shownErrors(tester)}');
    expect(find.text('用户1'), findsNothing, reason: '第一个标签的结果不该显示在第二个标签里');
    await savePng('query');

    // 补全：目录是连上之后从真库读的，候选要带上真实的表名
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

    await tester.tap(find.byKey(const ValueKey('tab-1')));
    await settleUntil(tester, find.text('用户1'));
    expect(find.text('用户1'), findsOneWidget, reason: '切回第一个标签，结果要还在');

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

    // 结构模式和服务器模式在真库上能打开
    await tester.tap(find.byKey(const ValueKey('mode-structure')));
    await settleUntil(tester, find.text('id'));
    await savePng('structure');
    await tester.tap(find.byKey(const ValueKey('mode-server')));
    await settleUntil(tester, find.text('CData'));
    await savePng('server');
    await tester.tap(find.text('用户与权限'));
    await settleUntil(tester, find.textContaining(_user));
    await savePng('users');
    await tester.tap(find.byKey(const ValueKey('mode-content')));
    await settle(tester, rounds: 1);

    // 多连接：从标题菜单新开一条连到 information_schema，再切回来
    await tester.tap(find.byKey(const ValueKey('connection-title')));
    await settle(tester, rounds: 1);
    await tester.tap(find.text('新建连接…'));
    await settle(tester, rounds: 1);
    await connect('information_schema');
    await settleUntil(tester, find.text('TABLES'));
    expect(find.text('TABLES'), findsWidgets, reason: '第二条连接的侧栏没列出 information_schema 的表。${shownErrors(tester)}');

    await tester.tap(find.byKey(const ValueKey('connection-title')));
    await settle(tester, rounds: 1);
    await tester.tap(find.textContaining('切换到').first);
    await settleUntil(tester, find.text('用户1'));
    expect(find.text('用户1'), findsOneWidget, reason: '切回第一条连接，原来的标签和结果要还在');

    // 窗口缩到最小尺寸，界面不能溢出。溢出会抛 FlutterError，测试框架据此判失败
    tester.view.physicalSize = const Size(1800, 1200);
    await settle(tester, rounds: 2);
    await savePng('narrow');
  });
}
