import 'package:flutter/material.dart';

/// 应用主题。浅色和原来的 ThemeData(colorSchemeSeed: Colors.indigo) 生成同一套 colorScheme
ThemeData appTheme(Brightness brightness) {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: brightness),
  );
}
