import 'package:flutter/material.dart';

import 'query_page.dart';
import 'src/rust/api/preferences.dart' as prefs;
import 'src/rust/frb_generated.dart';
import 'theme.dart';

Future<void> main() async {
  await RustLib.init();

  // 起窗口之前读好偏好，免得深色用户先闪一下浅色
  prefs.Preferences preferences;
  String? startupError;
  try {
    preferences = await prefs.loadPreferences();
  } catch (e) {
    preferences = prefs.defaultPreferences();
    startupError = '读取偏好设置失败，这次先用默认值：$e';
  }

  runApp(CDataApp(initialPreferences: preferences, startupError: startupError));
}

class CDataApp extends StatefulWidget {
  final prefs.Preferences initialPreferences;
  final String? startupError;

  const CDataApp({super.key, required this.initialPreferences, this.startupError});

  @override
  State<CDataApp> createState() => _CDataAppState();
}

class _CDataAppState extends State<CDataApp> {
  late prefs.Preferences _preferences = widget.initialPreferences;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CData',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: themeModeOf(_preferences.theme),
      home: QueryPage(
        preferences: _preferences,
        onPreferencesChanged: (preferences) => setState(() => _preferences = preferences),
        startupError: widget.startupError,
      ),
    );
  }
}

ThemeMode themeModeOf(prefs.ThemeMode theme) {
  return switch (theme) {
    prefs.ThemeMode.system => ThemeMode.system,
    prefs.ThemeMode.light => ThemeMode.light,
    prefs.ThemeMode.dark => ThemeMode.dark,
  };
}
