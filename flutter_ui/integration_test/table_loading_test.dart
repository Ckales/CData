// 用延迟响应在原生窗口验证切表蒙层，不连接数据库。
import 'dart:async';

import 'package:cdata_flutter/query_tab.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/fakes.dart';
import '../test/query_tab_test.dart' show FakeRunner, FakeLibrary, fakeTokenize;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('切表蒙层在明暗主题中覆盖旧结果并在成功或失败后消失', (tester) async {
    for (final brightness in Brightness.values) {
      final runner = FakeRunner();
      final key = GlobalKey<QueryTabState>();
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(brightness),
        theme: appTheme(brightness),
        home: Scaffold(
          body: QueryTab(
            key: key,
            runner: runner,
            library: FakeLibrary(),
            tokenize: fakeTokenize,
            onRan: (_) {},
            onConnected: () {},
            showEditor: false,
          ),
        ),
      ));
      await key.currentState!.runSql('SELECT * FROM first');
      await tester.pumpAndSettle();
      await tester.tap(find.text('用户1'));
      await tester.pump();
      runner.pending = Completer<QuerySummary>();
      final loading = key.currentState!.runSql('SELECT * FROM second');
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('正在加载表数据…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(AbsorbPointer).evaluate().any((e) => (e.widget as AbsorbPointer).absorbing), isTrue);
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('row-number-0'))));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('删除 1 行'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      debugPrint('CDATA_LOADING_PREVIEW_${brightness.name}');
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 5)));
      runner.pending!.complete(FakeGridSource.rows(2).summary);
      await loading;
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);

      runner.pending = Completer<QuerySummary>();
      final failed = key.currentState!.runSql('SELECT * FROM broken');
      await tester.pump();
      runner.pending!.completeError(Exception('加载失败'));
      await failed;
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
