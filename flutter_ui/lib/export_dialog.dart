import 'package:flutter/material.dart';

import 'mac_widgets.dart';
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
      title: const Text('导出'),
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      key: const ValueKey('export-header'),
                      value: _header,
                      onChanged: (value) => setState(() => _header = value ?? true),
                    ),
                    const Text('第一行写列名', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ] else
              FormRow(
                label: '表名',
                labelWidth: 80,
                child: TextField(
                  key: const ValueKey('export-table'),
                  controller: _table,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(hintText: '留空用结果集的来源表'),
                ),
              ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('导出…')),
      ],
    );
  }

  /// 弹出按钮按内容宽度靠左，不拉满整行（macOS 表单的排法）
  Widget _row(String label, Widget field) {
    return FormRow(
      label: label,
      labelWidth: 80,
      child: Align(alignment: Alignment.centerLeft, child: field),
    );
  }

  Widget _dropdown<T>(String key, T value, Map<T, String> items, void Function(T value) onChanged) {
    return MacPopupButton<T>(
      key: ValueKey(key),
      value: value,
      items: items,
      onChanged: (selected) => setState(() => onChanged(selected)),
    );
  }
}
