import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 字段表格的行选择。用对象身份跟随插入、删除及移动，复制时读取当前草稿名。
class StructureColumnSelection extends StatefulWidget {
  final List<Object> rows;
  final List<String> names;
  final Widget Function(int? selectedRow, ValueChanged<int> selectRow) builder;

  const StructureColumnSelection({
    super.key,
    required this.rows,
    required this.names,
    required this.builder,
  });

  @override
  State<StructureColumnSelection> createState() =>
      _StructureColumnSelectionState();
}

class _StructureColumnSelectionState extends State<StructureColumnSelection> {
  final _focus = FocusNode();
  Object? _selected;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _select(int index) {
    setState(() => _selected = widget.rows[index]);
    // 输入框已经在此焦点子树中时，让它继续处理文本选择和复制。
    if (!_focus.hasFocus) _focus.requestFocus();
  }

  void _copy() {
    final index = _selected == null ? -1 : widget.rows.indexOf(_selected!);
    if (index >= 0) {
      Clipboard.setData(ClipboardData(text: widget.names[index]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = _selected == null ? -1 : widget.rows.indexOf(_selected!);
    return Focus(
      focusNode: _focus,
      onKeyEvent: (node, event) {
        final keyboard = HardwareKeyboard.instance;
        if (node.hasPrimaryFocus &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyC &&
            (keyboard.isMetaPressed || keyboard.isControlPressed) &&
            !keyboard.isAltPressed && !keyboard.isShiftPressed) {
          _copy();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: widget.builder(index < 0 ? null : index, _select),
    );
  }
}
