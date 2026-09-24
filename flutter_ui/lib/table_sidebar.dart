import 'package:flutter/material.dart';

import 'data_source.dart';
import 'src/rust/api/schema.dart';

/// 左侧的库表清单。选库、过滤、点表浏览数据，右键看结构。
class TableSidebar extends StatefulWidget {
  final SchemaSource source;
  final String database;
  final void Function(String database) onDatabaseChanged;
  final void Function(String table) onTableSelected;

  /// 右键菜单里的「查看结构」。null 就不给这一项
  final void Function(String table)? onShowStructure;

  const TableSidebar({
    super.key,
    required this.source,
    required this.database,
    required this.onDatabaseChanged,
    required this.onTableSelected,
    this.onShowStructure,
  });

  @override
  State<TableSidebar> createState() => _TableSidebarState();
}

class _TableSidebarState extends State<TableSidebar> {
  final _filter = TextEditingController();

  List<String> _databases = [];
  List<TableInfo> _tables = [];
  String? _selectedTable;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(TableSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.database != widget.database) {
      _reload();
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final databases = await widget.source.databases();
      final tables = await widget.source.tables(widget.database);
      if (!mounted) return;
      setState(() {
        _databases = databases;
        _tables = tables;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<TableInfo> get _visibleTables {
    final keyword = _filter.text.trim().toLowerCase();
    if (keyword.isEmpty) return _tables;

    final matched = <TableInfo>[];
    for (final table in _tables) {
      if (table.name.toLowerCase().contains(keyword)) {
        matched.add(table);
      }
    }
    return matched;
  }

  void _browse(String table) {
    setState(() => _selectedTable = table);
    widget.onTableSelected(table);
  }

  /// 右键菜单，出现在鼠标位置
  Future<void> _showMenu(String table, Offset position) async {
    final onShowStructure = widget.onShowStructure;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(
          value: 'browse',
          height: 32,
          child: Text('浏览数据', style: TextStyle(fontSize: 12)),
        ),
        if (onShowStructure != null)
          const PopupMenuItem(
            value: 'structure',
            height: 32,
            child: Text('查看结构', style: TextStyle(fontSize: 12)),
          ),
      ],
    );
    if (!mounted) return;
    if (choice == 'browse') _browse(table);
    if (choice == 'structure' && onShowStructure != null) onShowStructure(table);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleTables;

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: const Border(right: BorderSide(color: Colors.black26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: _DatabasePicker(
              databases: _databases,
              current: widget.database,
              onChanged: widget.onDatabaseChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: TextField(
              controller: _filter,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                hintText: '过滤表名',
                hintStyle: TextStyle(fontSize: 12),
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 14),
                prefixIconConstraints: BoxConstraints(minWidth: 28, minHeight: 28),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: TextStyle(fontSize: 11, color: Colors.red.shade700)),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: visible.length,
              itemExtent: 26,
              itemBuilder: (context, index) {
                final table = visible[index];
                return _TableRow(
                  table: table,
                  selected: table.name == _selectedTable,
                  onTap: () => _browse(table.name),
                  onSecondaryTapDown: (position) => _showMenu(table.name, position),
                );
              },
            ),
          ),
          _SidebarFooter(count: visible.length, total: _tables.length, loading: _loading),
        ],
      ),
    );
  }
}

class _DatabasePicker extends StatelessWidget {
  final List<String> databases;
  final String current;
  final void Function(String database) onChanged;

  const _DatabasePicker({required this.databases, required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // 当前库可能还没出现在列表里（刚连上、或者没权限列库），先补进去免得下拉崩掉
    final items = databases.contains(current) ? databases : [current, ...databases];

    return DropdownButtonFormField<String>(
      initialValue: current,
      isDense: true,
      // 库名长了会把侧栏撑破，必须让它自适应宽度再省略
      isExpanded: true,
      style: const TextStyle(fontSize: 12, color: Colors.black87),
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        prefixIcon: Icon(Icons.storage, size: 14),
        prefixIconConstraints: BoxConstraints(minWidth: 28, minHeight: 28),
      ),
      items: [
        for (final database in items)
          DropdownMenuItem(
            value: database,
            child: Text(database, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

class _TableRow extends StatelessWidget {
  final TableInfo table;
  final bool selected;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onSecondaryTapDown;

  const _TableRow({
    required this.table,
    required this.selected,
    required this.onTap,
    required this.onSecondaryTapDown,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onSecondaryTapDown: (details) => onSecondaryTapDown(details.globalPosition),
      child: Container(
        color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(
              table.isView ? Icons.visibility_outlined : Icons.table_rows_outlined,
              size: 13,
              color: Colors.black45,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                table.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            // InnoDB 的行数是估算值，标个 ~ 免得被当成精确数字
            if (!table.isView && table.estimatedRows > BigInt.zero)
              Text(
                '~${table.estimatedRows}',
                style: const TextStyle(fontSize: 10, color: Colors.black38),
              ),
          ],
        ),
      ),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  final int count;
  final int total;
  final bool loading;

  const _SidebarFooter({required this.count, required this.total, required this.loading});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.black12)),
      ),
      child: Row(
        children: [
          Text(
            count == total ? '$total 张表' : '$count / $total 张表',
            style: const TextStyle(fontSize: 10, color: Colors.black45),
          ),
          const Spacer(),
          // 同 result_grid：无限动画会把 pumpAndSettle 卡死
          if (loading) const Text('加载中…', style: TextStyle(fontSize: 10, color: Colors.black45)),
        ],
      ),
    );
  }
}
