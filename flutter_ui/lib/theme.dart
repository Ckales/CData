import 'package:flutter/material.dart';

/// 应用主题。浅色和原来的 ThemeData(colorSchemeSeed: Colors.indigo) 生成同一套 colorScheme
ThemeData appTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    // 输入框提示要一眼和真值分开：默认提示色和正文太接近，一排空框看起来像都填了值。
    // 局部写了 hintStyle 会整个替换这里（InputDecoration.applyDefaults 是 ??，不是 merge），
    // 所以各处都不写 hintStyle；提示的字号跟着输入框自己的 style 走
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: TextStyle(fontStyle: FontStyle.italic, color: scheme.outline),
    ),
  );
}
