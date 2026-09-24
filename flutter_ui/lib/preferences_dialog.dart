import 'package:flutter/material.dart';

import 'src/rust/api/preferences.dart' as prefs;

/// 偏好设置。取值范围在 core 校验，save 抛错就把原因显示在对话框里、不关窗。
/// 保存成功返回新的偏好，取消返回 null
Future<prefs.Preferences?> showPreferencesDialog(
  BuildContext context, {
  required prefs.Preferences initial,
  required Future<void> Function(prefs.Preferences preferences) save,
}) {
  return showDialog<prefs.Preferences>(
    context: context,
    builder: (context) => _PreferencesDialog(initial: initial, save: save),
  );
}

class _PreferencesDialog extends StatefulWidget {
  final prefs.Preferences initial;
  final Future<void> Function(prefs.Preferences preferences) save;

  const _PreferencesDialog({required this.initial, required this.save});

  @override
  State<_PreferencesDialog> createState() => _PreferencesDialogState();
}

class _PreferencesDialogState extends State<_PreferencesDialog> {
  late prefs.ThemeMode _theme = widget.initial.theme;
  late final _fontSize = TextEditingController(text: '${widget.initial.editorFontSize}');
  late final _maxRows = TextEditingController(text: '${widget.initial.maxRows}');
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _fontSize.dispose();
    _maxRows.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final fontSize = int.tryParse(_fontSize.text.trim());
    if (fontSize == null) {
      setState(() => _error = '编辑器字号要填整数');
      return;
    }
    final maxRows = BigInt.tryParse(_maxRows.text.trim());
    if (maxRows == null) {
      setState(() => _error = '行数上限要填整数');
      return;
    }

    final preferences = prefs.Preferences(theme: _theme, editorFontSize: fontSize, maxRows: maxRows);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(preferences);
      if (mounted) Navigator.of(context).pop(preferences);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('偏好设置'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('外观', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            SegmentedButton<prefs.ThemeMode>(
              segments: const [
                ButtonSegment(value: prefs.ThemeMode.system, label: Text('跟随系统')),
                ButtonSegment(value: prefs.ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: prefs.ThemeMode.dark, label: Text('深色')),
              ],
              selected: {_theme},
              onSelectionChanged: (selected) => setState(() => _theme = selected.first),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('pref-font-size'),
              controller: _fontSize,
              decoration: const InputDecoration(labelText: '编辑器字号', isDense: true),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('pref-max-rows'),
              controller: _maxRows,
              decoration: const InputDecoration(
                labelText: '查询行数上限',
                helperText: '超过就截断并提示',
                isDense: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(fontSize: 12, color: scheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
      ],
    );
  }
}
