import 'package:flutter/material.dart';

import 'src/rust/api/db.dart';

/// 导出选项对话框。返回选项和「是否只导出选中区域」；取消返回 null
Future<({ExportOptions options, bool selectionOnly})?> showExportDialog(
  BuildContext context, {
  required int totalRows,
  required String? selectionLabel,
  required String suggestedTable,
}) {
  return showDialog(
    context: context,
    builder: (context) => _ExportDialog(
      totalRows: totalRows,
      selectionLabel: selectionLabel,
      suggestedTable: suggestedTable,
    ),
  );
}

class _ExportDialog extends StatefulWidget {
  final int totalRows;

  /// 有选区时的描述，比如「3 行 × 2 列」；没有选区是 null
  final String? selectionLabel;
  final String suggestedTable;

  const _ExportDialog({
    required this.totalRows,
    required this.selectionLabel,
    required this.suggestedTable,
  });

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  ExportFormat _format = ExportFormat.csv;
  ExportEncoding _encoding = ExportEncoding.utf8;
  String _delimiter = ',';
  bool _header = true;
  // 和剪贴板一致，默认把 NULL 写成不带引号的 NULL，不和空字符串混
  String _nullText = 'NULL';
  late bool _selectionOnly = widget.selectionLabel != null;
  late final _table = TextEditingController(text: widget.suggestedTable);

  @override
  void dispose() {
    _table.dispose();
    super.dispose();
  }

  void _submit() {
    final options = ExportOptions(
      format: _format,
      encoding: _encoding,
      delimiter: _delimiter,
      header: _header,
      nullText: _nullText,
      tableName: _table.text.trim(),
    );
    Navigator.of(context).pop((options: options, selectionOnly: _selectionOnly));
  }

  @override
  Widget build(BuildContext context) {
    final selectionLabel = widget.selectionLabel;

    return AlertDialog(
      title: const Text('导出', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _row(
              '格式',
              _dropdown<ExportFormat>(
                'export-format',
                _format,
                const {ExportFormat.csv: 'CSV', ExportFormat.sqlInsert: 'SQL INSERT'},
                (value) => _format = value,
              ),
            ),
            _row(
              '范围',
              _dropdown<bool>(
                'export-range',
                _selectionOnly,
                {
                  false: '全部 ${widget.totalRows} 行',
                  if (selectionLabel != null) true: '选中区域（$selectionLabel）',
                },
                (value) => _selectionOnly = value,
              ),
            ),
            _row(
              '编码',
              _dropdown<ExportEncoding>(
                'export-encoding',
                _encoding,
                const {
                  ExportEncoding.utf8: 'UTF-8',
                  ExportEncoding.utf8Bom: 'UTF-8（带 BOM，给 Excel）',
                  ExportEncoding.gbk: 'GBK',
                },
                (value) => _encoding = value,
              ),
            ),
            if (_format == ExportFormat.csv) ...[
              _row(
                '分隔符',
                _dropdown<String>(
                  'export-delimiter',
                  _delimiter,
                  const {',': '逗号 ,', ';': '分号 ;', '\t': '制表符'},
                  (value) => _delimiter = value,
                ),
              ),
              _row(
                'NULL 写成',
                _dropdown<String>(
                  'export-null',
                  _nullText,
                  const {'NULL': 'NULL', '': '空（空字符串写成 ""）', r'\N': r'\N'},
                  (value) => _nullText = value,
                ),
              ),
              _row(
                '列名',
                Checkbox(
                  key: const ValueKey('export-header'),
                  value: _header,
                  onChanged: (value) => setState(() => _header = value ?? true),
                ),
              ),
            ] else
              _row(
                '表名',
                TextField(
                  key: const ValueKey('export-table'),
                  controller: _table,
                  style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '留空用结果集的来源表',
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('导出…')),
      ],
    );
  }

  Widget _row(String label, Widget field) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: field)),
        ],
      ),
    );
  }

  Widget _dropdown<T>(String key, T value, Map<T, String> items, void Function(T value) onChanged) {
    return DropdownButton<T>(
      key: ValueKey(key),
      value: value,
      isDense: true,
      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
      items: [
        for (final entry in items.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      onChanged: (selected) {
        if (selected != null) setState(() => onChanged(selected));
      },
    );
  }
}
