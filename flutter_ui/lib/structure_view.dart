import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data_source.dart';
import 'mac_widgets.dart';
import 'src/rust/api/schema.dart';
import 'structure_editor.dart';
import 'theme.dart';

/// 表结构对话框：Dialog 里包一个 StructurePanel，外加标题和关闭按钮
Future<void> showTableStructure(
  BuildContext context, {
  required SchemaSource source,
  required String database,
  required String table,
  VoidCallback? onAltered,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 900,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Text('$database.$table', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StructurePanel(source: source, database: database, table: table, onAltered: onAltered),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 表结构面板：默认编辑，可切到只读结构查看建表语句。
/// 没有外框和关闭按钮，可以直接嵌进页面；database / table 变了会重读
class StructurePanel extends StatefulWidget {
  final SchemaSource source;
  final String database;
  final String table;

  /// 结构改动执行成功后立刻调（不等关窗），调用方据此刷新补全目录等
  final VoidCallback? onAltered;

  const StructurePanel({
    super.key,
    required this.source,
    required this.database,
    required this.table,
    this.onAltered,
  });

  @override
  State<StructurePanel> createState() => _StructurePanelState();
}

class _StructurePanelState extends State<StructurePanel> {
  TableStructure? _structure;
  String? _error;
  bool _copied = false;
  bool _editing = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StructurePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source == widget.source &&
        oldWidget.database == widget.database &&
        oldWidget.table == widget.table) {
      return;
    }
    // 换了表先清空，不让上一张表的结构顶着新表名显示
    setState(() {
      _structure = null;
      _error = null;
      _copied = false;
      _editing = true;
    });
    _load();
  }

  Future<void> _load() async {
    final source = widget.source;
    final database = widget.database;
    final table = widget.table;
    // 回来时已经换了表，这份结果作废
    bool stale() => !mounted || source != widget.source || database != widget.database || table != widget.table;
    try {
      final structure = await source.structure(database, table);
      if (stale()) return;
      setState(() => _structure = structure);
    } catch (e) {
      if (stale()) return;
      setState(() => _error = '$e');
    }
  }

  /// 改完重读，页面上显示的永远是库里现在的结构
  Future<void> _afterApplied() async {
    widget.onAltered?.call();
    if (!mounted) return;
    setState(() {
      _structure = null;
      _error = null;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final structure = _structure;
    return IndexedStack(
      index: structure != null && _editing ? 0 : 1,
      children: [
        if (structure != null)
          StructureEditorPanel(
            source: widget.source,
            database: widget.database,
            table: widget.table,
            structure: structure,
            onApplied: _afterApplied,
            onCancel: () => setState(() => _editing = false),
          )
        else
          const SizedBox.shrink(),
        _readOnly(structure),
      ],
    );
  }

  Widget _readOnly(TableStructure? structure) {
    final mac = MacColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    // 分页控制器放在最外层：换表时停在同一页，像 Querious 一样
    return DefaultTabController(
      length: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MacPanelBar(
            children: [
              if (structure != null)
                Expanded(
                  child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    dividerHeight: 0,
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                    indicatorSize: TabBarIndicatorSize.tab,
                    indicator: BoxDecoration(
                      border: Border(bottom: BorderSide(color: mac.accent, width: 2)),
                    ),
                    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                    splashFactory: NoSplash.splashFactory,
                    labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                    unselectedLabelStyle: const TextStyle(fontSize: 11),
                    labelColor: mac.accent,
                    unselectedLabelColor: scheme.onSurfaceVariant,
                    tabs: [
                      Tab(height: 31, text: '列 ${structure.columns.length}'),
                      Tab(height: 31, text: '索引 ${structure.indexes.length}'),
                      Tab(height: 31, text: '外键 ${structure.foreignKeys.length}'),
                      // null 是服务器读不了，不是没有，标签上不写 0
                      Tab(height: 31, text: structure.checks == null ? 'CHECK' : 'CHECK ${structure.checks!.length}'),
                      const Tab(height: 31, text: '建表语句'),
                    ],
                  ),
                )
              else
                const Spacer(),
              if (structure != null)
                OutlinedButton.icon(
                  onPressed: () => setState(() => _editing = true),
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('编辑'),
                ),
            ],
          ),
          Expanded(child: _body(structure)),
        ],
      ),
    );
  }

  Widget _body(TableStructure? structure) {
    final error = _error;
    if (error != null) {
      return Center(
        child: SelectableText('读取结构失败：$error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    // 加载状态用静态文字，不用转圈：无限动画会让 widget 测试的 pumpAndSettle 挂死
    if (structure == null) return const Center(child: Text('加载中…'));

    return TabBarView(
      children: [
        _columnsTab(structure),
        _indexesTab(structure),
        _foreignKeysTab(structure),
        _checksTab(structure),
        _ddlTab(structure),
      ],
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
    if (structure.indexes.isEmpty) return _empty('没有索引');
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
    if (structure.foreignKeys.isEmpty) return _empty('没有外键');
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

  Widget _checksTab(TableStructure structure) {
    final checks = structure.checks;
    if (checks == null) return _empty('这个服务器读不到 CHECK 约束（要 MySQL 8.0.16+）');
    if (checks.isEmpty) return _empty('没有 CHECK 约束');
    return _Grid(
      headers: const ['名称', '表达式', '强制执行'],
      widths: const [200, 480, 120],
      rows: [
        for (final check in checks)
          [
            _text(check.name, bold: true),
            _text(check.expression, mono: true),
            _text(check.enforced ? '是' : '否（NOT ENFORCED）', muted: !check.enforced),
          ],
      ],
    );
  }

  Widget _ddlTab(TableStructure structure) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            color: scheme.surface,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                structure.createSql,
                style: const TextStyle(fontSize: 12, fontFamily: 'Menlo', height: 1.5),
              ),
            ),
          ),
        ),
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: structure.createSql));
              if (mounted) setState(() => _copied = true);
            },
            icon: const Icon(Icons.copy, size: 14),
            label: Text(_copied ? '已复制' : '复制'),
          ),
        ),
      ],
    );
  }

  Widget _empty(String text) {
    return Center(
      child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontWeight: bold ? FontWeight.w500 : null,
        fontFamily: mono ? 'Menlo' : null,
        fontStyle: italic ? FontStyle.italic : null,
        color: muted ? Theme.of(context).colorScheme.onSurfaceVariant : null,
      ),
    );
  }
}

/// 固定列宽的列表，像 NSTableView：灰底表头带竖分隔，行 22px 隔行变色，横竖都能滚。
/// 结构页的行数有限，不用虚拟滚动
class _Grid extends StatefulWidget {
  final List<String> headers;
  final List<double> widths;
  final List<List<Widget>> rows;

  const _Grid({required this.headers, required this.widths, required this.rows});

  @override
  State<_Grid> createState() => _GridState();
}

class _GridState extends State<_Grid> {
  final _hScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var totalWidth = 0.0;
    for (final width in widget.widths) {
      totalWidth += width;
    }

    return ColoredBox(
      color: scheme.surface,
      child: LayoutBuilder(
        builder: (context, constraints) => Scrollbar(
          controller: _hScroll,
          thumbVisibility: true,
          interactive: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: SingleChildScrollView(
            controller: _hScroll,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              // 比面板窄时撑满，最后一列后面的空白也画出表头和隔行底色
              width: totalWidth > constraints.maxWidth ? totalWidth : constraints.maxWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 29,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
                    ),
                    child: _cells([
                      for (final header in widget.headers)
                        Text(
                          header,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
                        ),
                    ], divider: scheme.outlineVariant),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: widget.rows.length,
                      itemExtent: 29,
                      itemBuilder: (context, index) => ColoredBox(
                        color: index.isOdd ? scheme.surfaceContainerLow : scheme.surface,
                        child: DecoratedBox(
                          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
                          child: _cells(widget.rows[index]),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cells(List<Widget> cells, {Color? divider}) {
    return Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          Container(
            width: widget.widths[i],
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            decoration: divider == null ? null : BoxDecoration(border: Border(right: BorderSide(color: divider))),
            child: cells[i],
          ),
      ],
    );
  }
}
