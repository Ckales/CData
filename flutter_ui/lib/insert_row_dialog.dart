import 'package:flutter/material.dart';

import 'mac_widgets.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/value.dart';

/// 新行里某一列怎么写
enum _Mode { useDefault, null_, value }

/// 新增行的表单。返回每列的值，null 表示交给 DEFAULT / 自增；取消返回 null。
///
/// 「不写」「写 NULL」「写空字符串」是三件事，每列显式选，不靠输入框空不空来猜。
Future<List<CellValue?>?> showInsertRowDialog(BuildContext context, List<ColumnMeta> columns) {
  return showDialog<List<CellValue?>>(
    context: context,
    builder: (context) => _InsertRowDialog(columns: columns),
  );
}

class _InsertRowDialog extends StatefulWidget {
  final List<ColumnMeta> columns;

  const _InsertRowDialog({required this.columns});

  @override
  State<_InsertRowDialog> createState() => _InsertRowDialogState();
}

class _InsertRowDialogState extends State<_InsertRowDialog> {
  late final List<_Mode> _modes = List.filled(widget.columns.length, _Mode.useDefault);
  late final List<TextEditingController> _controllers = [
    for (final _ in widget.columns) TextEditingController(),
  ];

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = <CellValue?>[];
    for (var i = 0; i < widget.columns.length; i++) {
      switch (_modes[i]) {
        case _Mode.useDefault:
          values.add(null);
        case _Mode.null_:
          values.add(const CellValue.null_());
        case _Mode.value:
          values.add(CellValue.text(_controllers[i].text));
      }
    }
    Navigator.of(context).pop(values);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新增行'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.columns.length; i++) _columnRow(i),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('插入')),
      ],
    );
  }

  Widget _columnRow(int index) {
    final column = widget.columns[index];

    return FormRow(
      label: column.name,
      labelWidth: 140,
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: MacPopupButton<_Mode>(
              key: ValueKey('insert-mode-$index'),
              value: _modes[index],
              items: const {_Mode.useDefault: '默认', _Mode.null_: 'NULL', _Mode.value: '值'},
              disabled: column.isBinary ? const {_Mode.value} : const {},
              onChanged: (mode) => setState(() => _modes[index] = mode),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              key: ValueKey('insert-field-$index'),
              controller: _controllers[index],
              enabled: !column.isBinary,
              style: const TextStyle(fontSize: 12),
              // 边框、底色、提示样式沿用主题，只压低高度和弹出按钮对齐
              decoration: InputDecoration(
                // 紧凑输入框的高度是 10 + 上下内边距，6 正好 22px，和弹出按钮一样高
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                hintText: column.isBinary ? '二进制列暂不支持输入' : _hint(_modes[index]),
              ),
              // 一打字就是要写这个值，省得再去切下拉框
              onChanged: (_) => setState(() => _modes[index] = _Mode.value),
            ),
          ),
        ],
      ),
    );
  }

  String? _hint(_Mode mode) {
    return switch (mode) {
      _Mode.useDefault => '不写，交给默认值 / 自增',
      _Mode.null_ => 'NULL',
      _Mode.value => null,
    };
  }
}
