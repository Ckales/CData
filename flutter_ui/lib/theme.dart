import 'package:flutter/material.dart';

/// 应用主题：照 Querious / macOS 原生的样子做，不用 Material 默认的大号控件。
///
/// 系统字体、13pt 正文、紧凑密度、系统蓝选中色、浅灰侧栏和工具栏、白色内容区。
/// 两个平台用同一套（Windows 上字体落到 Segoe UI，其余一样）。
ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final mac = dark ? MacColors.dark : MacColors.light;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: mac.accent,
    onPrimary: Colors.white,
    primaryContainer: dark ? const Color(0xFF16345C) : const Color(0xFFD6E6FF),
    onPrimaryContainer: dark ? const Color(0xFFD6E6FF) : const Color(0xFF002E6B),
    secondary: mac.accent,
    onSecondary: Colors.white,
    tertiary: dark ? const Color(0xFFFF9F0A) : const Color(0xFFB25000),
    onTertiary: Colors.white,
    // 截断提示这类「警告但不是错误」的底色
    tertiaryContainer: dark ? const Color(0xFF4A3510) : const Color(0xFFFFEFD1),
    onTertiaryContainer: dark ? const Color(0xFFFFE0A8) : const Color(0xFF5C3300),
    error: dark ? const Color(0xFFFF453A) : const Color(0xFFD70015),
    onError: Colors.white,
    errorContainer: dark ? const Color(0xFF4A1512) : const Color(0xFFFFE5E7),
    onErrorContainer: dark ? const Color(0xFFFFD2CF) : const Color(0xFF7A000C),
    surface: mac.content,
    onSurface: mac.text,
    onSurfaceVariant: mac.secondaryText,
    surfaceContainerLowest: mac.content,
    surfaceContainerLow: mac.zebra,
    surfaceContainer: mac.window,
    surfaceContainerHigh: mac.sidebar,
    surfaceContainerHighest: mac.toolbar,
    outline: mac.tertiaryText,
    outlineVariant: mac.separator,
    inverseSurface: dark ? const Color(0xFFECECEC) : const Color(0xFF2B2B2D),
    onInverseSurface: dark ? const Color(0xFF1D1D1F) : const Color(0xFFF5F5F7),
    shadow: Colors.black,
  );

  // 正文 13pt，辅助文字 11pt：和 macOS 的 body / small 一样。Material 默认 14–16pt 太大
  final base = ThemeData(brightness: brightness).textTheme;
  final text = base.copyWith(
    bodyLarge: base.bodyLarge!.copyWith(fontSize: 13),
    bodyMedium: base.bodyMedium!.copyWith(fontSize: 13),
    bodySmall: base.bodySmall!.copyWith(fontSize: 11),
    labelLarge: base.labelLarge!.copyWith(fontSize: 13, fontWeight: FontWeight.w500),
    labelMedium: base.labelMedium!.copyWith(fontSize: 12),
    labelSmall: base.labelSmall!.copyWith(fontSize: 11),
    titleSmall: base.titleSmall!.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
    titleMedium: base.titleMedium!.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
    titleLarge: base.titleLarge!.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
    headlineSmall: base.headlineSmall!.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
  ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

  const radius = BorderRadius.all(Radius.circular(6));
  const buttonShape = RoundedRectangleBorder(borderRadius: radius);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 12);
  const buttonSize = Size(0, 26);
  final buttonText = text.labelLarge;

  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    textTheme: text,
    extensions: [mac],
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    scaffoldBackgroundColor: mac.content,
    canvasColor: mac.content,
    dividerTheme: DividerThemeData(color: mac.separator, thickness: 1, space: 1),
    iconTheme: IconThemeData(size: 16, color: mac.secondaryText),
    // 默认按钮：白底细边框、6px 圆角，和 macOS 的 push button 一样；主按钮是实心系统蓝
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: buttonText,
        backgroundColor: mac.accent,
        foregroundColor: Colors.white,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: buttonText,
        foregroundColor: mac.text,
        backgroundColor: mac.control,
        side: BorderSide(color: mac.controlBorder),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: buttonSize,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        shape: buttonShape,
        textStyle: buttonText,
        foregroundColor: mac.accent,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(26, 26),
        padding: const EdgeInsets.all(4),
        iconSize: 16,
        shape: buttonShape,
        foregroundColor: mac.secondaryText,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        minimumSize: buttonSize,
        textStyle: text.bodyMedium,
        shape: buttonShape,
        side: BorderSide(color: mac.controlBorder),
        selectedBackgroundColor: mac.accent,
        selectedForegroundColor: Colors.white,
      ),
    ),
    // 输入框：白底、细边框、5px 圆角，聚焦时一圈系统蓝，像 NSTextField
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: mac.control,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      border: OutlineInputBorder(borderRadius: const BorderRadius.all(Radius.circular(5)), borderSide: BorderSide(color: mac.controlBorder)),
      enabledBorder: OutlineInputBorder(borderRadius: const BorderRadius.all(Radius.circular(5)), borderSide: BorderSide(color: mac.controlBorder)),
      focusedBorder: OutlineInputBorder(borderRadius: const BorderRadius.all(Radius.circular(5)), borderSide: BorderSide(color: mac.accent, width: 2)),
      disabledBorder: OutlineInputBorder(borderRadius: const BorderRadius.all(Radius.circular(5)), borderSide: BorderSide(color: mac.separator)),
      labelStyle: TextStyle(fontSize: 12, color: mac.secondaryText),
      floatingLabelBehavior: FloatingLabelBehavior.never,
      // 输入框提示要一眼和真值分开：默认提示色和正文太接近，一排空框看起来像都填了值。
      // 局部写了 hintStyle 会整个替换这里（InputDecoration.applyDefaults 是 ??，不是 merge），
      // 所以各处都不写 hintStyle；提示的字号跟着输入框自己的 style 走
      hintStyle: TextStyle(fontStyle: FontStyle.italic, color: scheme.outline),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: mac.window,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: mac.content,
      surfaceTintColor: Colors.transparent,
      textStyle: text.bodyMedium,
      shape: const RoundedRectangleBorder(borderRadius: radius),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius))),
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: const TextStyle(fontSize: 11, color: Colors.white),
      decoration: BoxDecoration(color: const Color(0xE6333336), borderRadius: BorderRadius.circular(4)),
      waitDuration: const Duration(milliseconds: 500),
    ),
    tabBarTheme: TabBarThemeData(
      labelStyle: text.bodyMedium!.copyWith(fontWeight: FontWeight.w600),
      unselectedLabelStyle: text.bodyMedium,
      labelColor: mac.text,
      unselectedLabelColor: mac.secondaryText,
      indicatorColor: mac.accent,
      dividerColor: mac.separator,
    ),
    checkboxTheme: CheckboxThemeData(
      visualDensity: VisualDensity.compact,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(3))),
      side: BorderSide(color: mac.controlBorder),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(7),
      radius: const Radius.circular(4),
      thumbColor: WidgetStatePropertyAll(mac.text.withValues(alpha: 0.28)),
    ),
    listTileTheme: ListTileThemeData(dense: true, titleTextStyle: text.bodyMedium, subtitleTextStyle: text.bodySmall),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, contentTextStyle: text.bodyMedium!.copyWith(color: Colors.white)),
  );
}

/// macOS 特有、ColorScheme 里没有对应位置的颜色。取法：`MacColors.of(context)`
@immutable
class MacColors extends ThemeExtension<MacColors> {
  /// 窗口底色：对话框、偏好设置、连接页
  final Color window;

  /// 工具栏和表头
  final Color toolbar;

  /// 侧栏
  final Color sidebar;

  /// 内容区（网格、编辑器）
  final Color content;

  /// 网格的隔行底色
  final Color zebra;

  /// 分隔线、网格线
  final Color separator;

  /// 系统蓝：选中、主按钮、焦点环
  final Color accent;

  /// 控件底色和边框（输入框、普通按钮）
  final Color control;
  final Color controlBorder;

  final Color text;
  final Color secondaryText;
  final Color tertiaryText;

  /// 侧栏里表、库的图标颜色（Querious 用的蓝色表格图标）
  final Color tableIcon;
  final Color databaseIcon;

  const MacColors({
    required this.window,
    required this.toolbar,
    required this.sidebar,
    required this.content,
    required this.zebra,
    required this.separator,
    required this.accent,
    required this.control,
    required this.controlBorder,
    required this.text,
    required this.secondaryText,
    required this.tertiaryText,
    required this.tableIcon,
    required this.databaseIcon,
  });

  static const light = MacColors(
    window: Color(0xFFECECEC),
    toolbar: Color(0xFFE3E3E3),
    sidebar: Color(0xFFE8E8E8),
    content: Color(0xFFFFFFFF),
    zebra: Color(0xFFF4F5F5),
    separator: Color(0xFFD9D9DC),
    accent: Color(0xFF0A64D6),
    control: Color(0xFFFFFFFF),
    controlBorder: Color(0xFFC4C4C8),
    text: Color(0xFF1D1D1F),
    secondaryText: Color(0xFF5E5E63),
    tertiaryText: Color(0xFF8E8E93),
    tableIcon: Color(0xFF2F7CF6),
    databaseIcon: Color(0xFF3A8DFF),
  );

  static const dark = MacColors(
    window: Color(0xFF2A2A2C),
    toolbar: Color(0xFF323235),
    sidebar: Color(0xFF28282A),
    content: Color(0xFF1E1E20),
    zebra: Color(0xFF252528),
    separator: Color(0xFF3C3C40),
    accent: Color(0xFF2F7CF6),
    control: Color(0xFF2C2C2F),
    controlBorder: Color(0xFF4A4A4E),
    text: Color(0xFFECECEE),
    secondaryText: Color(0xFFA6A6AB),
    tertiaryText: Color(0xFF7E7E83),
    tableIcon: Color(0xFF5B9BFF),
    databaseIcon: Color(0xFF6AA8FF),
  );

  /// 主题里没挂这组颜色（widget 测试里直接用 MaterialApp 默认主题）时，按亮度给默认的 Mac 配色，
  /// 不因为少一个扩展就整页崩掉
  static MacColors of(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<MacColors>();
    if (colors != null) return colors;
    return theme.brightness == Brightness.dark ? dark : light;
  }

  @override
  MacColors copyWith() => this;

  @override
  MacColors lerp(MacColors? other, double t) {
    if (other == null) return this;
    return MacColors(
      window: Color.lerp(window, other.window, t)!,
      toolbar: Color.lerp(toolbar, other.toolbar, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      content: Color.lerp(content, other.content, t)!,
      zebra: Color.lerp(zebra, other.zebra, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      control: Color.lerp(control, other.control, t)!,
      controlBorder: Color.lerp(controlBorder, other.controlBorder, t)!,
      text: Color.lerp(text, other.text, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      tertiaryText: Color.lerp(tertiaryText, other.tertiaryText, t)!,
      tableIcon: Color.lerp(tableIcon, other.tableIcon, t)!,
      databaseIcon: Color.lerp(databaseIcon, other.databaseIcon, t)!,
    );
  }
}
