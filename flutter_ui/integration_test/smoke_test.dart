// 端到端冒烟：连真库 → 查询 → 界面显示，顺便把主界面导出成 PNG。
//
// 细粒度的 UI 行为都在 test/ 下的 widget 测试里（秒级，不连库）；
// 这里只验证"整条链路接得上"，以及出一张图用来看效果。
//
// 运行：见 run_integration_tests.sh

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cdata_flutter/query_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
          home: const QueryPage(),
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
  });
}
