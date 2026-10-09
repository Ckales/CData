import 'package:flutter/material.dart';

/// 桌面工作区主题：紧凑工具栏、分栏和表格，浅色与暗色使用同一套层级。
/// 两个平台用同一套（Windows 上字体落到 Segoe UI，其余一样）。
ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final mac = dark ? MacColors.dark : MacColors.light;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: mac.accent,
    onPrimary: Colors.white,
    primaryContainer: dark ? const Color(0xFF2E4768) : const Color(0xFFD6E4F5),
    onPrimaryContainer: dark
        ? const Color(0xFFE8F1FF)
        : const Color(0xFF215A9E),
    secondary: mac.accent,
    onSecondary: Colors.white,
    tertiary: dark ? const Color(0xFFF0C27F) : const Color(0xFFA96D1F),
    onTertiary: Colors.white,
    // 警告但不是错误的底色。indigo 种子的 tertiaryContainer 是粉色，这里改成琥珀
    tertiaryContainer: dark ? const Color(0xFF4A3823) : const Color(0xFFFFF3DF),
    onTertiaryContainer: dark
        ? const Color(0xFFF0C27F)
        : const Color(0xFFA96D1F),
    error: dark ? const Color(0xFFF29B9B) : const Color(0xFFB04C4B),
    onError: Colors.white,
    errorContainer: dark ? const Color(0xFF4B2D33) : const Color(0xFFFFF0EE),
    onErrorContainer: dark ? const Color(0xFFF29B9B) : const Color(0xFFB04C4B),
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

  // 工作区以 12pt 为基线，表格和辅助文字 11pt。
  final base = ThemeData(brightness: brightness).textTheme;
  final text = base
      .copyWith(
        bodyLarge: base.bodyLarge!.copyWith(fontSize: 13),
        bodyMedium: base.bodyMedium!.copyWith(fontSize: 12),
        bodySmall: base.bodySmall!.copyWith(fontSize: 11),
        labelLarge: base.labelLarge!.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: base.labelMedium!.copyWith(fontSize: 11),
        labelSmall: base.labelSmall!.copyWith(fontSize: 11),
        titleSmall: base.titleSmall!.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: base.titleMedium!.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: base.titleLarge!.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        headlineSmall: base.headlineSmall!.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      )
      .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

  const radius = BorderRadius.all(Radius.circular(4));
  const buttonShape = RoundedRectangleBorder(borderRadius: radius);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 3);
  // 按钮固定 24px 高（macOS 普通按钮的高度）。按钮自己用标准密度：全局的 compact 会从最小高度里
  // 再减 8px，按钮就只剩 18px，边框贴着字，很难看
  const buttonSize = Size(0, 26);
  const buttonDensity = VisualDensity.standard;
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
    dividerTheme: DividerThemeData(
      color: mac.separator,
      thickness: 1,
      space: 1,
    ),
    iconTheme: IconThemeData(size: 16, color: mac.secondaryText),
    // 默认按钮：白底细边框、6px 圆角，和 macOS 的 push button 一样；主按钮是实心系统蓝
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: buttonSize,
        visualDensity: buttonDensity,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
        visualDensity: buttonDensity,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
        visualDensity: buttonDensity,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        shape: buttonShape,
        textStyle: buttonText,
        foregroundColor: mac.accent,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(25, 25),
        padding: const EdgeInsets.all(4),
        iconSize: 15,
        shape: buttonShape,
        foregroundColor: mac.secondaryText,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      // 模式切换保留原生分段控件的浅色选中面。
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(0, 24),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        visualDensity: const VisualDensity(horizontal: -2, vertical: -4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: text.bodyMedium,
        shape: buttonShape,
        side: BorderSide(color: mac.controlBorder),
        foregroundColor: mac.text,
        backgroundColor: mac.control,
        selectedBackgroundColor: dark ? const Color(0xFF455F86) : mac.content,
        selectedForegroundColor: dark ? const Color(0xFFEDF4FF) : mac.accent,
      ),
    ),
    // 输入框：白底、细边框、5px 圆角，聚焦时一圈系统蓝，像 NSTextField
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: mac.control,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: mac.controlBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: mac.controlBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: mac.accent, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: mac.separator),
      ),
      labelStyle: TextStyle(fontSize: 12, color: mac.secondaryText),
      floatingLabelBehavior: FloatingLabelBehavior.never,
      // 输入框提示要一眼和真值分开：默认提示色和正文太接近，一排空框看起来像都填了值。
      // 局部写了 hintStyle 会整个替换这里（InputDecoration.applyDefaults 是 ??，不是 merge），
      // 所以各处都不写 hintStyle；提示的字号跟着输入框自己的 style 走
      hintStyle: TextStyle(fontStyle: FontStyle.italic, color: scheme.outline),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: mac.content,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: mac.control,
      surfaceTintColor: Colors.transparent,
      textStyle: text.bodyMedium!.copyWith(fontSize: 12),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      elevation: 8,
      shadowColor: dark ? const Color(0x8000050C) : const Color(0x26263343),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(7),
        side: BorderSide(color: mac.controlBorder),
      ),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: const TextStyle(fontSize: 11, color: Colors.white),
      decoration: BoxDecoration(
        color: const Color(0xE6333336),
        borderRadius: BorderRadius.circular(4),
      ),
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      side: BorderSide(color: mac.controlBorder),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(7),
      radius: const Radius.circular(4),
      thumbColor: WidgetStatePropertyAll(mac.text.withValues(alpha: 0.28)),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      titleTextStyle: text.bodyMedium,
      subtitleTextStyle: text.bodySmall,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      contentTextStyle: text.bodyMedium!.copyWith(color: Colors.white),
    ),
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

  /// 侧栏里表、库的低对比图标色。
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
    window: Color(0xFFF7F8FA),
    toolbar: Color(0xFFEBEEF2),
    sidebar: Color(0xFFE9EAEC),
    content: Color(0xFFFFFFFF),
    zebra: Color(0xFFF9FAFB),
    separator: Color(0xFFD5DBE3),
    accent: Color(0xFF4672C4),
    control: Color(0xFFFFFFFF),
    controlBorder: Color(0xFFCBD3DE),
    text: Color(0xFF17243B),
    secondaryText: Color(0xFF5A6B80),
    tertiaryText: Color(0xFF91A2B8),
    tableIcon: Color(0xFF91A2B8),
    databaseIcon: Color(0xFF73869D),
  );

  static const dark = MacColors(
    window: Color(0xFF222B35),
    toolbar: Color(0xFF29323D),
    sidebar: Color(0xFF252E39),
    content: Color(0xFF1B232D),
    zebra: Color(0xFF202A35),
    separator: Color(0xFF354150),
    accent: Color(0xFF638FF0),
    control: Color(0xFF263442),
    controlBorder: Color(0xFF46576B),
    text: Color(0xFFE4EBF4),
    secondaryText: Color(0xFF9BABBf),
    tertiaryText: Color(0xFF7F91A6),
    tableIcon: Color(0xFF8FA5BA),
    databaseIcon: Color(0xFFA8BDD3),
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
