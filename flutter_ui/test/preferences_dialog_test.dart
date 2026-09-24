import 'package:cdata_flutter/preferences_dialog.dart';
import 'package:cdata_flutter/src/rust/api/preferences.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart' hide ThemeMode;
import 'package:flutter_test/flutter_test.dart';

final _initial = Preferences(theme: ThemeMode.system, editorFontSize: 13, maxRows: BigInt.from(100000));

/// 打开对话框，把结果放进 result 里
Future<void> _open(
  WidgetTester tester,
  Future<void> Function(Preferences preferences) save,
  void Function(Preferences? result) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => onResult(await showPreferencesDialog(context, initial: _initial, save: save)),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 切到左边的某个分类
Future<void> _category(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('选深色、改行数后保存，返回的是新值', (tester) async {
    Preferences? saved;
    Preferences? result;
    await _open(tester, (preferences) async => saved = preferences, (value) => result = value);

    await _category(tester, '外观');
    await tester.tap(find.text('深色'));
    await _category(tester, '通用');
    await tester.enterText(find.byKey(const ValueKey('pref-max-rows')), '5000');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved!.theme, ThemeMode.dark);
    expect(saved!.maxRows, BigInt.from(5000));
    expect(saved!.editorFontSize, 13);
    expect(result!.theme, ThemeMode.dark);
    expect(find.text('偏好设置'), findsNothing, reason: '保存成功要关窗');
  });

  testWidgets('core 拒绝的值：显示原因，不关窗', (tester) async {
    Preferences? result;
    var closed = false;
    await _open(
      tester,
      (preferences) async => throw '行数上限要在 1 到 100000 之间，现在是 0',
      (value) {
        closed = true;
        result = value;
      },
    );

    await tester.enterText(find.byKey(const ValueKey('pref-max-rows')), '0');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('行数上限要在 1 到 100000 之间'), findsOneWidget);
    expect(find.text('偏好设置'), findsOneWidget);
    expect(closed, isFalse);
    expect(result, isNull);
  });

  testWidgets('字号不是整数：不调 save，直接提示', (tester) async {
    var called = false;
    await _open(tester, (preferences) async => called = true, (_) {});

    await _category(tester, '查询编辑');
    await tester.enterText(find.byKey(const ValueKey('pref-font-size')), '大号');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(called, isFalse);
    expect(find.text('编辑器字号要填整数'), findsOneWidget);
  });

  testWidgets('切分类不丢没保存的输入；快捷键页只读列出', (tester) async {
    Preferences? saved;
    await _open(tester, (preferences) async => saved = preferences, (_) {});

    await tester.enterText(find.byKey(const ValueKey('pref-max-rows')), '2000');
    await _category(tester, '快捷键');
    expect(find.text('新建标签'), findsOneWidget);
    expect(find.text('执行编辑框里的 SQL'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: '快捷键只读');
    await _category(tester, '通用');
    expect(find.text('2000'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved!.maxRows, BigInt.from(2000));
  });
}
