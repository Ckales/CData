import 'package:file_selector/file_selector.dart' show XTypeGroup, getSaveLocation;
import 'package:flutter/material.dart';

import 'mac_widgets.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/schema.dart' show TableInfo;

/// 弹系统保存对话框选导出位置，按建议文件名的扩展名过滤。取消返回 null
Future<String?> pickExportPath(String suggestedName) async {
  final extension = suggestedName.split('.').last;
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: [XTypeGroup(label: extension.toUpperCase(), extensions: [extension])],
  );
  return location?.path;
}

/// SQL 多表导出的选择。null 表示不是这条路径（CSV，或结果集导出）
typedef SqlDumpChoice = ({
  List<String> tables,
  bool createDatabase,
  bool dropTable,
  bool createTable,
  bool includeData,
});

/// 导出选项对话框。返回选项和「是否只导出选中区域」；取消返回 null。
/// allRowsLabel 是「全部」那一项的写法，比如「全部 120 行」「整张表」。
/// tables 非空时，SQL 格式可以勾选多张表，或全选导出整个库
Future<({ExportOptions options, bool selectionOnly, SqlDumpChoice? dump})?> showExportDialog(
  BuildContext context, {
  required String allRowsLabel,
  required String? selectionLabel,
  required String suggestedTable,
  List<TableInfo> tables = const [],
  String? currentTable,
  bool selectAll = false,
  ExportFormat initialFormat = ExportFormat.csv,
}) {
  return showDialog(
    context: context,
    builder: (context) => _ExportDialog(
      allRowsLabel: allRowsLabel,
      selectionLabel: selectionLabel,
      suggestedTable: suggestedTable,
      tables: tables,
      currentTable: currentTable,
      selectAll: selectAll,
      initialFormat: initialFormat,
    ),
  );
}

class _ExportDialog extends StatefulWidget {
  final String allRowsLabel;

  /// 有选区时的描述，比如「3 行 × 2 列」；没有选区是 null
  final String? selectionLabel;
  final String suggestedTable;
  final List<TableInfo> tables;
  final String? currentTable;

  /// 打开时勾上全部表，并带上建库语句
  final bool selectAll;
  final ExportFormat initialFormat;

  const _ExportDialog({
    required this.allRowsLabel,
    required this.selectionLabel,
    required this.suggestedTable,
    required this.tables,
    required this.currentTable,
    required this.selectAll,
    required this.initialFormat,
  });

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late ExportFormat _format = widget.initialFormat;
  ExportEncoding _encoding = ExportEncoding.utf8;
  String _delimiter = ',';
  bool _header = true;
  // 和剪贴板一致，默认把 NULL 写成不带引号的 NULL，不和空字符串混
  String _nullText = 'NULL';
  late bool _selectionOnly = widget.selectionLabel != null;
  late final _table = TextEditingController(text: widget.suggestedTable);
  final _filter = TextEditingController();

  late final Set<String> _selected = widget.selectAll
      ? widget.tables.map((table) => table.name).toSet()
      : {
          if (widget.currentTable != null && widget.tables.any((table) => table.name == widget.currentTable))
            widget.currentTable!,
        };
  late bool _createDatabase = widget.selectAll;
  bool _dropTable = true;
  bool _createTable = true;
  bool _includeData = true;

  bool get _dumping => widget.tables.isNotEmpty && _format == ExportFormat.sqlInsert;

  bool get _canExport {
    if (!_dumping) return true;
    if (_selected.isEmpty) return false;
    return _createDatabase || _dropTable || _createTable || _includeData;
  }

  @override
  void dispose() {
    _table.dispose();
    _filter.dispose();
    super.dispose();
  }

  void _setAll(bool on) {
    setState(() {
      if (on) {
        _selected.addAll(widget.tables.map((table) => table.name));
        _createDatabase = true;
      } else {
        _selected.clear();
      }
    });
  }

  void _toggle(String name, bool on) {
    setState(() {
      if (on) {
        _selected.add(name);
      } else {
        _selected.remove(name);
      }
    });
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
    // 按侧栏的顺序，不按勾选的先后
    final SqlDumpChoice? dump = _dumping
        ? (
            tables: [for (final table in widget.tables) if (_selected.contains(table.name)) table.name],
            createDatabase: _createDatabase,
            dropTable: _dropTable,
            createTable: _createTable,
            includeData: _includeData,
          )
        : null;
    Navigator.of(context).pop((options: options, selectionOnly: _selectionOnly, dump: dump));
  }

  @override
  Widget build(BuildContext context) {
    final selectionLabel = widget.selectionLabel;
    final dumping = _dumping;

    return AlertDialog(
      title: const Text('导出'),
      content: SizedBox(
        width: dumping ? 640 : 420,
        child: SingleChildScrollView(
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
              if (!dumping)
                _row(
                  '范围',
                  _dropdown<bool>(
                    'export-range',
                    _selectionOnly,
                    {
                      false: widget.allRowsLabel,
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
              if (dumping)
                _dumpPane()
              else if (_format == ExportFormat.csv) ...[
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
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _canExport ? _submit : null, child: const Text('导出…')),
      ],
    );
  }

  /// 左边勾选表，右边是能重新导入的语句开关
  Widget _dumpPane() {
    final hint = Theme.of(context).hintColor;
    final visible = _visibleTables();
    final allValue = _selected.isEmpty
        ? false
        : _selected.length == widget.tables.length
            ? true
            : null;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 280,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Checkbox(
                          key: const ValueKey('export-select-all'),
                          tristate: true,
                          value: allValue,
                          onChanged: (_) => _setAll(_selected.length != widget.tables.length),
                        ),
                        const Text('全选', style: TextStyle(fontSize: 12)),
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            '已选 ${_selected.length} / ${widget.tables.length}',
                            style: TextStyle(fontSize: 11, color: hint),
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                      child: TextField(
                        key: const ValueKey('export-table-filter'),
                        controller: _filter,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '过滤表名',
                          prefixIcon: Icon(Icons.search, size: 16),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: visible.length,
                        itemExtent: 28,
                        itemBuilder: (context, index) {
                          final table = visible[index];
                          final checked = _selected.contains(table.name);
                          return InkWell(
                            key: ValueKey('export-table-${table.name}'),
                            onTap: () => _toggle(table.name, !checked),
                            child: Row(
                              children: [
                                IgnorePointer(
                                  child: Checkbox(
                                    value: checked,
                                    onChanged: (_) {},
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    table.name,
                                    style: const TextStyle(fontSize: 12),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (table.isView)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Text('视图', style: TextStyle(fontSize: 11, color: hint)),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SQL 选项', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  _check('export-create-database', _createDatabase, '建库语句', (value) => _createDatabase = value),
                  _check('export-drop-table', _dropTable, '删表语句', (value) => _dropTable = value),
                  _check('export-create-table', _createTable, '建表语句', (value) => _createTable = value),
                  _check('export-include-data', _includeData, '表数据', (value) => _includeData = value),
                  Text(
                    '删表语句在导入时会先删掉同名表。视图只导出结构。',
                    style: TextStyle(fontSize: 11, color: hint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<TableInfo> _visibleTables() {
    final keyword = _filter.text.trim().toLowerCase();
    if (keyword.isEmpty) return widget.tables;
    return [for (final table in widget.tables) if (table.name.toLowerCase().contains(keyword)) table];
  }

  Widget _check(String key, bool value, String label, void Function(bool value) onChanged) {
    return InkWell(
      onTap: () => setState(() => onChanged(!value)),
      child: Row(
        children: [
          IgnorePointer(
            child: Checkbox(
              key: ValueKey(key),
              value: value,
              onChanged: (_) {},
            ),
          ),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
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
