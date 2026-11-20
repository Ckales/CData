// 真实 FFI 默认值与统一偏好界面；不连接数据库、不修改用户偏好。
import 'package:cdata_flutter/preferences_dialog.dart';
import 'package:cdata_flutter/src/rust/api/preferences.dart' as prefs;
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rust_init.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureRustInit);

  testWidgets('通用偏好显示默认连接超时 180 秒，并可统一调整', (tester) async {
    final defaults = prefs.defaultPreferences();
    expect(defaults.connectTimeoutSecs, 180);
    prefs.Preferences? saved;
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: Builder(builder: (context) => TextButton(
        onPressed: () => showPreferencesDialog(
          context,
          initial: defaults,
          save: (value) async { saved = value; },
        ),
        child: const Text('打开偏好设置'),
      )),
    ));
    await tester.tap(find.text('打开偏好设置'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('pref-connect-timeout'));
    await tester.ensureVisible(field);
    expect(tester.widget<TextField>(field).controller!.text, '180');
    await tester.enterText(field, '300');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved!.connectTimeoutSecs, 300);
    expect(tester.takeException(), isNull);
  });
}
