// 深色主题下的配色回归测试：数据正确性相关的占位和提示必须取自 colorScheme，
// 并且和普通文本、错误提示分得开，不能是写死的黑色。

import 'dart:math' as math;

import 'package:cdata_flutter/result_grid.dart';
import 'package:cdata_flutter/sql_editor.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/editor.dart';
import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// 实际画出来的颜色：Text 自己的 style 合并 DefaultTextStyle 之后的结果
Color? paintedColor(WidgetTester tester, Finder finder) {
  return tester.renderObject<RenderParagraph>(finder).text.style?.color;
}

/// WCAG 对比度。带透明度的前景先叠到背景上再算
double contrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

void main() {
  final dark = appTheme(Brightness.dark).colorScheme;

  testWidgets('深色主题下 NULL、二进制、解码失败、空字符串、截断、只读原因都能一眼区分', (tester) async {
    final source = FakeGridSource(
      summary: summaryOf(
        columns: [column('a'), column('b'), column('c'), column('d'), column('e')],
        totalRows: 1,
        truncated: true,
        editability: const Editability.readOnly('表 no_pk 没有主键，无法安全定位行，不能编辑'),
      ),
      rows: [
        [
          const CellValue.text('abc'),
          const CellValue.null_(),
          CellValue.bytes(bytesOf(12)),
          CellValue.invalidText(bytesOf(2)),
          const CellValue.text(''),
        ],
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(body: ResultGrid(source: source)),
      ),
    );
    await tester.pumpAndSettle();

    final normal = paintedColor(tester, find.text('abc'));
    expect(normal, dark.onSurface, reason: '普通文本跟着深色 onSurface 走');

    for (final placeholder in ['NULL', '<二进制 12 字节>', '<无法解码 2 字节>']) {
      final color = paintedColor(tester, find.text(placeholder))!;
      expect(color, dark.onSurface.withValues(alpha: 0.38), reason: '$placeholder 取自深色 colorScheme');
      expect(contrast(color, dark.surface), greaterThanOrEqualTo(3), reason: '$placeholder 在深色背景上看得清');
      // 占位和真实文本要靠颜色拉开差距，不能只靠斜体
      final blended = Color.alphaBlend(color, dark.surface);
      expect(contrast(normal!, blended), greaterThanOrEqualTo(3), reason: '$placeholder 和普通文本分得开');
    }

    // 空字符串什么都不画，和显示成「NULL」的 NULL 不会混
    expect(
      find.descendant(of: find.byKey(const ValueKey('cell-0-4')), matching: find.text('')),
      findsOneWidget,
    );

    // 截断提示：底色不能和错误横幅撞色，文字在底色上要清楚
    final banner = tester.widget<Container>(
      find.ancestor(of: find.textContaining('已截断'), matching: find.byType(Container)).first,
    );
    expect(banner.color, isNot(dark.errorContainer));
    expect(contrast(paintedColor(tester, find.textContaining('已截断'))!, banner.color!), greaterThanOrEqualTo(4.5));

    expect(
      paintedColor(tester, find.textContaining('没有主键')),
      dark.onSurfaceVariant,
      reason: '只读原因用次要文字色，不是写死的 black54',
    );
  });

  test('深色 SQL 高亮在深色 surface 上对比度够', () {
    for (final kind in SqlTokenKind.values) {
      final color = tokenStyle(kind, Brightness.dark)?.color;
      if (color == null) continue;
      expect(contrast(color, dark.surface), greaterThanOrEqualTo(4.5), reason: '$kind');
    }
  });

  testWidgets('输入框提示在两种主题下都是斜体浅色，和真值分得开', (tester) async {
    for (final brightness in Brightness.values) {
      final theme = appTheme(brightness);
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: Column(children: [
            TextField(style: TextStyle(fontSize: 11), decoration: InputDecoration(hintText: '提示')),
            TextField(),
          ]),
        ),
      ));
      await tester.enterText(find.byType(TextField).last, '真值');
      // 换主题时 MaterialApp 会渐变过去，等动画走完再读颜色
      await tester.pumpAndSettle();
      // 读实际画出来的样式
      final hint = tester.renderObject<RenderParagraph>(find.text('提示')).text.style!;
      expect(hint.fontStyle, FontStyle.italic, reason: '$brightness');
      expect(hint.color, theme.colorScheme.outline);
      expect(hint.fontSize, 11, reason: '提示字号跟着输入框自己的 style');
    }
  });
}
