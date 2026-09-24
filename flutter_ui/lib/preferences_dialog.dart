import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'mac_widgets.dart';
import 'src/rust/api/preferences.dart' as prefs;
import 'theme.dart';

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

/// 左边的分类，和 Querious 的偏好设置窗口一样一类一页
enum _Category { general, appearance, editor, shortcuts }

const _categoryLabels = {
  _Category.general: '通用',
  _Category.appearance: '外观',
  _Category.editor: '查询编辑',
  _Category.shortcuts: '快捷键',
};

const _categoryIcons = {
  _Category.general: Icons.tune,
  _Category.appearance: Icons.palette_outlined,
  _Category.editor: Icons.edit_note,
  _Category.shortcuts: Icons.keyboard_outlined,
};

class _PreferencesDialog extends StatefulWidget {
  final prefs.Preferences initial;
  final Future<void> Function(prefs.Preferences preferences) save;

  const _PreferencesDialog({required this.initial, required this.save});

  @override
  State<_PreferencesDialog> createState() => _PreferencesDialogState();
}

class _PreferencesDialogState extends State<_PreferencesDialog> {
  _Category _category = _Category.general;
  late prefs.ThemeMode _theme = widget.initial.theme;
  // 控制器放在对话框这一层：切分类时输入框卸下来，填了没保存的值还在
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
    final mac = MacColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final error = _error;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 680,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 像 macOS 窗口的标题栏：居中的标题，底下一条分隔线
            Container(
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: mac.toolbar,
                border: Border(bottom: BorderSide(color: mac.separator)),
              ),
              child: const Text('偏好设置', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 170,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: mac.sidebar,
                      border: Border(right: BorderSide(color: mac.separator)),
                    ),
                    child: ListView(
                      children: [
                        for (final category in _Category.values)
                          SidebarItem(
                            key: ValueKey('pref-category-${category.name}'),
                            icon: _categoryIcons[category]!,
                            iconColor: mac.accent,
                            label: _categoryLabels[category]!,
                            selected: category == _category,
                            onTap: () => setState(() => _category = category),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(20, 20, 24, 12),
                            child: _page(),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 16, 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: error == null
                                    ? const SizedBox.shrink()
                                    : Text(error, style: TextStyle(fontSize: 12, color: scheme.error)),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
                              const SizedBox(width: 8),
                              FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _page() {
    return switch (_category) {
      _Category.general => _general(),
      _Category.appearance => _appearance(),
      _Category.editor => _editor(),
      _Category.shortcuts => _shortcuts(),
    };
  }

  Widget _note(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: _labelWidth + 8, bottom: 4),
      child: Text(text, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }

  static const double _labelWidth = 110;

  Widget _general() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormRow(
          label: '查询行数上限',
          labelWidth: _labelWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 120,
              child: TextField(key: const ValueKey('pref-max-rows'), controller: _maxRows),
            ),
          ),
        ),
        _note('一次查询最多取回这么多行，超过就截断并提示'),
      ],
    );
  }

  Widget _appearance() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormRow(
          label: '外观',
          labelWidth: _labelWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<prefs.ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: prefs.ThemeMode.system, label: Text('跟随系统')),
                ButtonSegment(value: prefs.ThemeMode.light, label: Text('浅色')),
                ButtonSegment(value: prefs.ThemeMode.dark, label: Text('深色')),
              ],
              selected: {_theme},
              onSelectionChanged: (selected) => setState(() => _theme = selected.first),
            ),
          ),
        ),
      ],
    );
  }

  Widget _editor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormRow(
          label: '编辑器字号',
          labelWidth: _labelWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 80,
              child: TextField(key: const ValueKey('pref-font-size'), controller: _fontSize),
            ),
          ),
        ),
        _note('SQL 编辑框用的等宽字号，单位 pt'),
      ],
    );
  }

  /// 只读：快捷键写死在页面外层，这里列出来备查。Windows 上 ⌘ 是 Ctrl
  Widget _shortcuts() {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final command = mac ? '⌘' : 'Ctrl+';
    final control = mac ? '⌃' : 'Ctrl+';
    final shift = mac ? '⇧' : 'Shift+';
    final shortcuts = [
      ('${command}T', '新建标签'),
      ('${command}W', '关闭当前标签'),
      ('${command}1 – ${command}8', '切到第 1 – 8 个标签'),
      ('${command}9', '切到最后一个标签'),
      ('${control}Tab', '下一个标签'),
      ('$control${shift}Tab', '上一个标签'),
      ('${command}Enter', '执行编辑框里的 SQL'),
      ('${control}Space', '唤出补全'),
      ('$command,', '偏好设置'),
    ];
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < shortcuts.length; i++)
            Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: i.isOdd ? scheme.surfaceContainerLow : scheme.surface,
              child: Row(
                children: [
                  Expanded(child: Text(shortcuts[i].$2, style: const TextStyle(fontSize: 13))),
                  Text(
                    shortcuts[i].$1,
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
