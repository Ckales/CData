import 'package:flutter/material.dart';

import 'mac_widgets.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/value.dart';

/// 新行里某一列怎么写
enum _Mode { useDefault, null_, value }

/// 新增行的表单。返回每列的值，null 表示交给 DEFAULT / 自增；取消返回 null。
///
/// 「不写」「写 NULL」「写空字符串」是三件事，每列显式选，不靠输入框空不空来猜。
/// initial 是「复制行」带进来的原值，initial[i] 为 null 表示这一列用默认（比如主键交给自增）
Future<List<CellValue?>?> showInsertRowDialog(
  BuildContext context,
  List<ColumnMeta> columns, {
  List<CellValue?>? initial,
}) {
  return showDialog<List<CellValue?>>(
    context: context,
    builder: (context) => _InsertRowDialog(columns: columns, initial: initial),
  );
}

class _InsertRowDialog extends StatefulWidget {
  final List<ColumnMeta> columns;
  final List<CellValue?>? initial;

  const _InsertRowDialog({required this.columns, required this.initial});

  @override
  State<_InsertRowDialog> createState() => _InsertRowDialogState();
}

class _InsertRowDialogState extends State<_InsertRowDialog> {
  late final List<_Mode> _modes = List.filled(widget.columns.length, _Mode.useDefault);
  late final List<TextEditingController> _controllers = [
    for (final _ in widget.columns) TextEditingController(),
  ];

  /// 复制行时带进来的二进制原值。二进制没法在输入框里改，选「值」就原样写回这份字节
  late final List<CellValue?> _binaryOriginals = List.filled(widget.columns.length, null);

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial == null) return;
    for (var i = 0; i < initial.length; i++) {
      final value = initial[i];
      switch (value) {
        case null:
          _modes[i] = _Mode.useDefault;
        case CellValue_Null():
          _modes[i] = _Mode.null_;
        case CellValue_Int(:final field0):
          _modes[i] = _Mode.value;
          _controllers[i].text = field0.toString();
        case CellValue_UInt(:final field0):
          _modes[i] = _Mode.value;
          _controllers[i].text = field0.toString();
        case CellValue_Double(:final field0):
          _modes[i] = _Mode.value;
          _controllers[i].text = field0.toString();
        case CellValue_Text(:final field0):
          _modes[i] = _Mode.value;
          _controllers[i].text = field0;
        case CellValue_Bytes():
        case CellValue_InvalidText():
          _modes[i] = _Mode.value;
          _binaryOriginals[i] = value;
      }
    }
  }

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
          values.add(_binaryOriginals[i] ?? CellValue.text(_controllers[i].text));
      }
    }
    Navigator.of(context).pop(values);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '新增行' : '复制为新行'),
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
    final binaryOriginal = _binaryOriginals[index];
    // 二进制原值、解码失败的文本都没法在输入框里编辑，只能原样写回或换成默认 / NULL
    final locked = column.isBinary || binaryOriginal != null;

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
              disabled: binaryOriginal == null && column.isBinary ? const {_Mode.value} : const {},
              onChanged: (mode) => setState(() => _modes[index] = mode),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              key: ValueKey('insert-field-$index'),
              controller: _controllers[index],
              enabled: !locked,
              style: const TextStyle(fontSize: 12),
              // 边框、底色、提示样式沿用主题，只压低高度和弹出按钮对齐
              decoration: InputDecoration(
                // 紧凑输入框的高度是 10 + 上下内边距，6 正好 22px，和弹出按钮一样高
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                hintText: binaryOriginal != null && _modes[index] == _Mode.value
                    ? '保留原值（${_byteCount(binaryOriginal)} 字节）'
                    : column.isBinary
                    ? '二进制列暂不支持输入'
                    : _hint(_modes[index]),
              ),
              // 一打字就是要写这个值，省得再去切下拉框
              onChanged: (_) => setState(() => _modes[index] = _Mode.value),
            ),
          ),
        ],
      ),
    );
  }

  int _byteCount(CellValue value) {
    return switch (value) {
      CellValue_Bytes(:final field0) => field0.length,
      CellValue_InvalidText(:final field0) => field0.length,
      _ => throw StateError('不是二进制值：$value'),
    };
  }

  String? _hint(_Mode mode) {
    return switch (mode) {
      _Mode.useDefault => '不写，交给默认值 / 自增',
      _Mode.null_ => 'NULL',
      _Mode.value => null,
    };
  }
}
