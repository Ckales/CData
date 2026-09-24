import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data_source.dart';
import 'src/rust/api/schema.dart';

/// 表结构对话框：列 / 索引 / 外键 / 建表语句四页
Future<void> showTableStructure(
  BuildContext context, {
  required SchemaSource source,
  required String database,
  required String table,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _StructureDialog(source: source, database: database, table: table),
  );
}

class _StructureDialog extends StatefulWidget {
  final SchemaSource source;
  final String database;
  final String table;

  const _StructureDialog({required this.source, required this.database, required this.table});

  @override
  State<_StructureDialog> createState() => _StructureDialogState();
}

class _StructureDialogState extends State<_StructureDialog> {
  TableStructure? _structure;
  String? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final structure = await widget.source.structure(widget.database, widget.table);
      if (mounted) setState(() => _structure = structure);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 900,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '${widget.database}.${widget.table}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    iconSize: 18,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final error = _error;
    if (error != null) {
      return Center(
        child: SelectableText('读取结构失败：$error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    final structure = _structure;
    // 加载状态用静态文字，不用转圈：无限动画会让 widget 测试的 pumpAndSettle 挂死
    if (structure == null) return const Center(child: Text('加载中…'));

    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelStyle: const TextStyle(fontSize: 12),
            tabs: [
              Tab(text: '列 ${structure.columns.length}'),
              Tab(text: '索引 ${structure.indexes.length}'),
              Tab(text: '外键 ${structure.foreignKeys.length}'),
              const Tab(text: '建表语句'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _columnsTab(structure),
                _indexesTab(structure),
                _foreignKeysTab(structure),
                _ddlTab(structure),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _columnsTab(TableStructure structure) {
    final primary = <String>{};
    for (final index in structure.indexes) {
      if (index.name == 'PRIMARY') primary.addAll(index.columns);
    }

    return _Grid(
      headers: const ['', '列名', '类型', '可空', '默认值', '附加', '排序规则', '注释'],
      widths: const [22, 150, 170, 44, 150, 150, 140, 200],
      rows: [
        for (final column in structure.columns)
          [
            primary.contains(column.name)
                // 主键钥匙沿用约定俗成的金色：只是图标、不承载文字，深浅背景上都看得见
                ? const Icon(Icons.key, size: 12, color: Colors.amber)
                : const SizedBox.shrink(),
            _text(column.name, bold: true),
            _text(column.columnType, mono: true),
            _text(column.nullable ? '是' : '否'),
            _defaultValue(column.default_),
            _text(column.extra, mono: true),
            _text(column.collation ?? '', muted: true),
            _text(column.comment),
          ],
      ],
    );
  }

  /// 四种默认值要看得出区别：没有默认值、默认 NULL、字面量（带引号）、表达式（不带引号）
  Widget _defaultValue(DefaultValue value) {
    return switch (value) {
      DefaultValue_NoDefault() => _text('无', muted: true),
      DefaultValue_Null() => _text('NULL', muted: true, italic: true),
      DefaultValue_Literal(:final field0) => _text("'$field0'", mono: true),
      DefaultValue_Expression(:final field0) => _text(field0, mono: true),
    };
  }

  Widget _indexesTab(TableStructure structure) {
    if (structure.indexes.isEmpty) return const Center(child: Text('没有索引'));
    return _Grid(
      headers: const ['名称', '列', '唯一', '类型', '注释'],
      widths: const [180, 300, 50, 100, 240],
      rows: [
        for (final index in structure.indexes)
          [
            _text(index.name, bold: true),
            _text(index.columns.join(', '), mono: true),
            _text(index.unique ? '是' : '否'),
            _text(index.indexType, muted: true),
            _text(index.comment),
          ],
      ],
    );
  }

  Widget _foreignKeysTab(TableStructure structure) {
    if (structure.foreignKeys.isEmpty) return const Center(child: Text('没有外键'));
    return _Grid(
      headers: const ['名称', '列', '引用', 'ON UPDATE', 'ON DELETE'],
      widths: const [180, 180, 280, 110, 110],
      rows: [
        for (final fk in structure.foreignKeys)
          [
            _text(fk.name, bold: true),
            _text(fk.columns.join(', '), mono: true),
            _text(
              '${fk.referencedSchema}.${fk.referencedTable} (${fk.referencedColumns.join(', ')})',
              mono: true,
            ),
            _text(fk.onUpdate),
            _text(fk.onDelete),
          ],
      ],
    );
  }

  Widget _ddlTab(TableStructure structure) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: structure.createSql));
              if (mounted) setState(() => _copied = true);
            },
            icon: const Icon(Icons.copy, size: 14),
            label: Text(_copied ? '已复制' : '复制', style: const TextStyle(fontSize: 12)),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: SelectableText(
              structure.createSql,
              style: const TextStyle(fontSize: 12, fontFamily: 'Menlo', height: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _text(
    String text, {
    bool bold = false,
    bool mono = false,
    bool muted = false,
    bool italic = false,
  }) {
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontWeight: bold ? FontWeight.w600 : null,
        fontFamily: mono ? 'Menlo' : null,
        fontStyle: italic ? FontStyle.italic : null,
        color: muted ? Theme.of(context).colorScheme.onSurfaceVariant : null,
      ),
    );
  }
}

/// 固定列宽的小表格，横竖都能滚。结构页的行数有限，不用虚拟滚动
class _Grid extends StatelessWidget {
  final List<String> headers;
  final List<double> widths;
  final List<List<Widget>> rows;

  const _Grid({required this.headers, required this.widths, required this.rows});

  @override
  Widget build(BuildContext context) {
    var totalWidth = 0.0;
    for (final width in widths) {
      totalWidth += width;
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: totalWidth,
        child: Column(
          children: [
            _row(context, [
              for (final header in headers)
                Text(header, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            ], header: true),
            Expanded(child: ListView(children: [for (final row in rows) _row(context, row)])),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, List<Widget> cells, {bool header = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: header ? Theme.of(context).colorScheme.surfaceContainerHighest : null,
        border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < cells.length; i++)
            SizedBox(
              width: widths[i],
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: cells[i]),
            ),
        ],
      ),
    );
  }
}
