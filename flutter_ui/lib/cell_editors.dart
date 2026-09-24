// 按列类别选的单元格编辑器。每个编辑器返回要写入的值：null 表示取消，
// CellValue.null_() 表示明确写 NULL —— 两者不能混。
//
// 值怎么解释、JSON 合不合法都由 Rust 侧判断，这里只负责让人方便地输入。

import 'package:flutter/material.dart';

import 'src/rust/api/value.dart';

/// 编辑器底部的按钮：写 NULL / 取消 / 保存
List<Widget> _actions(BuildContext context, {required VoidCallback? onSave}) {
  return [
    TextButton(
      onPressed: () => Navigator.of(context).pop(const CellValue.null_()),
      child: const Text('写入 NULL'),
    ),
    TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
    FilledButton(onPressed: onSave, child: const Text('保存')),
  ];
}

Text _title(String column, String kind) {
  return Text('$column（$kind）', style: const TextStyle(fontSize: 15));
}

/// JSON：多行编辑，可以格式化；保存前先校验，不合法不让存
Future<CellValue?> showJsonEditor(
  BuildContext context, {
  required String column,
  required String initial,
  required Future<String> Function(String text) format,
}) {
  return showDialog<CellValue>(
    context: context,
    builder: (context) => _JsonEditor(column: column, initial: initial, format: format),
  );
}

class _JsonEditor extends StatefulWidget {
  final String column;
  final String initial;
  final Future<String> Function(String text) format;

  const _JsonEditor({required this.column, required this.initial, required this.format});

  @override
  State<_JsonEditor> createState() => _JsonEditorState();
}

class _JsonEditorState extends State<_JsonEditor> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _format() async {
    try {
      final formatted = await widget.format(_controller.text);
      if (!mounted) return;
      setState(() {
        _controller.text = formatted;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 存的是用户看到的文本。校验只是拦住不合法的输入，不替用户改内容
  Future<void> _save() async {
    try {
      await widget.format(_controller.text);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (mounted) Navigator.of(context).pop(CellValue.text(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          _title(widget.column, 'JSON'),
          const Spacer(),
          TextButton(onPressed: _format, child: const Text('格式化')),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('json-text'),
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 12, fontFamily: 'Menlo', height: 1.4),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: _actions(context, onSave: _save),
    );
  }
}

/// ENUM：从定义里的可选值单选
Future<CellValue?> showEnumEditor(
  BuildContext context, {
  required String column,
  required List<String> choices,
  required String? current,
}) {
  return showDialog<CellValue>(
    context: context,
    builder: (context) => AlertDialog(
      title: _title(column, 'ENUM'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final choice in choices)
                ListTile(
                  dense: true,
                  selected: choice == current,
                  leading: Icon(
                    choice == current ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 16,
                  ),
                  title: Text(choice, style: const TextStyle(fontSize: 13, fontFamily: 'Menlo')),
                  onTap: () => Navigator.of(context).pop(CellValue.text(choice)),
                ),
            ],
          ),
        ),
      ),
      // 单选点一下就写入，不需要保存按钮
      actions: _actions(context, onSave: null).sublist(0, 2),
    ),
  );
}

/// SET：多选，按定义顺序用逗号拼起来
Future<CellValue?> showSetEditor(
  BuildContext context, {
  required String column,
  required List<String> choices,
  required String? current,
}) {
  return showDialog<CellValue>(
    context: context,
    builder: (context) => _SetEditor(column: column, choices: choices, current: current),
  );
}

class _SetEditor extends StatefulWidget {
  final String column;
  final List<String> choices;
  final String? current;

  const _SetEditor({required this.column, required this.choices, required this.current});

  @override
  State<_SetEditor> createState() => _SetEditorState();
}

class _SetEditorState extends State<_SetEditor> {
  late final Set<String> _checked = {
    // MySQL 返回的 SET 值就是逗号分隔的成员；空串是空集合，NULL 也从空集合开始选
    if (widget.current != null && widget.current!.isNotEmpty) ...widget.current!.split(','),
  };

  void _save() {
    final ordered = <String>[];
    for (final choice in widget.choices) {
      if (_checked.contains(choice)) ordered.add(choice);
    }
    Navigator.of(context).pop(CellValue.text(ordered.join(',')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: _title(widget.column, 'SET'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final choice in widget.choices)
                CheckboxListTile(
                  dense: true,
                  value: _checked.contains(choice),
                  title: Text(choice, style: const TextStyle(fontSize: 13, fontFamily: 'Menlo')),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _checked.add(choice);
                    } else {
                      _checked.remove(choice);
                    }
                  }),
                ),
            ],
          ),
        ),
      ),
      actions: _actions(context, onSave: _save),
    );
  }
}

/// DATE / DATETIME：文本照常可改，另给一个日期选择器填日期部分。
/// 零日期、微秒这些选择器表示不了的写法，靠直接改文本
Future<CellValue?> showDateEditor(
  BuildContext context, {
  required String column,
  required String initial,
  required bool withTime,
}) {
  return showDialog<CellValue>(
    context: context,
    builder: (context) => _DateEditor(column: column, initial: initial, withTime: withTime),
  );
}

class _DateEditor extends StatefulWidget {
  final String column;
  final String initial;
  final bool withTime;

  const _DateEditor({required this.column, required this.initial, required this.withTime});

  @override
  State<_DateEditor> createState() => _DateEditorState();
}

class _DateEditorState extends State<_DateEditor> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final text = _controller.text;
    // 只用来给选择器定初始位置；零日期之类解析不了就从今天开始
    final seed = text.length >= 10 ? DateTime.tryParse(text.substring(0, 10)) : null;
    final picked = await showDatePicker(
      context: context,
      initialDate: seed ?? DateTime.now(),
      firstDate: DateTime(1000),
      lastDate: DateTime(9999, 12, 31),
    );
    if (picked == null || !mounted) return;

    final date = '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    // 只换日期部分，原来的时间（包括微秒）原样保留
    final keepsTime = seed != null && text.length > 10;
    final time = widget.withTime ? (keepsTime ? text.substring(10) : ' 00:00:00') : '';
    setState(() => _controller.text = '$date$time');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: _title(widget.column, widget.withTime ? 'DATETIME' : 'DATE'),
      content: SizedBox(
        width: 360,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('date-text'),
                controller: _controller,
                style: const TextStyle(fontSize: 13, fontFamily: 'Menlo'),
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: widget.withTime ? 'YYYY-MM-DD HH:MM:SS' : 'YYYY-MM-DD',
                ),
              ),
            ),
            IconButton(
              tooltip: '选择日期',
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_month, size: 18),
            ),
          ],
        ),
      ),
      actions: _actions(
        context,
        onSave: () => Navigator.of(context).pop(CellValue.text(_controller.text)),
      ),
    );
  }
}

/// TIME：一段时长，范围 -838:59:59 到 838:59:59，不是一天里的时刻，所以不用 TimePicker
/// （它只能选 0–23 点，也丢小数秒）。纯文本输入，格式和范围由 core 的 check 判断，
/// 这里只显示它给的错误；原文照写，不补零也不截断小数秒
Future<CellValue?> showTimeEditor(
  BuildContext context, {
  required String column,
  required String initial,
  required int fsp,
  required String? Function(String text) check,
}) {
  return showDialog<CellValue>(
    context: context,
    builder: (context) => _TimeEditor(column: column, initial: initial, fsp: fsp, check: check),
  );
}

class _TimeEditor extends StatefulWidget {
  final String column;
  final String initial;
  final int fsp;
  final String? Function(String text) check;

  const _TimeEditor({required this.column, required this.initial, required this.fsp, required this.check});

  @override
  State<_TimeEditor> createState() => _TimeEditorState();
}

class _TimeEditorState extends State<_TimeEditor> {
  late final _controller = TextEditingController(text: widget.initial);

  /// 当前输入的问题，null 表示合法。原值是 NULL 时输入框是空的，先不报错，等人开始输入
  late String? _error = widget.initial.isEmpty ? null : widget.check(widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final error = widget.check(_controller.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(CellValue.text(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    // 超过 6 是表达式列，小数秒位数不固定
    final precision = widget.fsp > 6 ? '最多 6 位小数秒' : (widget.fsp == 0 ? '不存小数秒' : '保留 ${widget.fsp} 位小数秒');
    return AlertDialog(
      title: _title(widget.column, 'TIME'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('time-text'),
              controller: _controller,
              style: const TextStyle(fontSize: 13, fontFamily: 'Menlo'),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '[-]时:分:秒[.微秒]',
              ),
              onChanged: (text) => setState(() => _error = widget.check(text)),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? '范围 -838:59:59 到 838:59:59，小时可以超过 24；这一列$precision',
              style: TextStyle(
                fontSize: 12,
                color: _error == null ? Theme.of(context).colorScheme.onSurfaceVariant : Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ),
      ),
      actions: _actions(context, onSave: _save),
    );
  }
}

/// 二进制内容只读查看。声明成文本却解不了码的列也走这里，并说明原因
Future<void> showHexViewer(
  BuildContext context, {
  required String column,
  required String dump,
  required int byteCount,
  required bool invalidText,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: _title(column, '$byteCount 字节'),
      content: SizedBox(
        width: 720,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (invalidText)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '这一列声明为文本，但内容不是合法的 UTF-8，下面是原始字节。不猜编码。',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  dump,
                  style: const TextStyle(fontSize: 12, fontFamily: 'Menlo', height: 1.4),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '二进制内容暂不支持在网格里编辑',
                style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
      ],
    ),
  );
}
