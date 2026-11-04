// 在 macOS 原生窗口验证结构行选择和系统剪贴板，不连接数据库。
import 'package:cdata_flutter/structure_view.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/fakes.dart';
import '../test/structure_view_test.dart' show sampleStructure;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('结构字段行在明暗主题及编辑只读视图中复制到系统剪贴板', (tester) async {
    for (final brightness in Brightness.values) {
      final source = FakeSchemaSource.simple()..structures['posts'] = sampleStructure();
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(brightness),
        theme: appTheme(brightness),
        home: Scaffold(body: StructurePanel(source: source, database: 'shop', table: 'posts')),
      ));
      await tester.pumpAndSettle();
      for (final editable in [true, false]) {
        if (!editable) {
          await tester.tap(find.text('查看'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('title'));
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.runAsync(() async {
          final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
          expect(clipboard?.text, 'title');
        });
        expect(source.applied, isEmpty);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
