import 'package:flutter/material.dart';

import 'data_source.dart';
import 'mac_widgets.dart';
import 'src/rust/api/schema.dart';
import 'theme.dart';

/// 左侧的库表清单（Querious 的样子）：库选择器、过滤框、蓝色表图标的紧凑列表。
/// 选库、过滤、点表浏览数据，右键看结构、导入、新建表。
class TableSidebar extends StatefulWidget {
  final SchemaSource source;
  final String database;

  /// 当前选中的表，由外面（当前标签）决定：每个标签记着自己选的是哪张表
  final String? selectedTable;
  final void Function(String database) onDatabaseChanged;
  final void Function(String table) onTableSelected;

  /// 右键菜单里的「查看结构」。null 就不给这一项
  final void Function(String table)? onShowStructure;

  /// 右键菜单里的「导入 CSV」。null 就不给这一项
  final void Function(String table)? onImport;

  /// 右键菜单里的「新建表…」，参数是当前库。返回建好的表名，侧栏据此重读并选中；
  /// 取消返回 null。null 就不给这一项
  final Future<String?> Function(String database)? onCreateTable;

  const TableSidebar({
    super.key,
    required this.source,
    required this.database,
    this.selectedTable,
    required this.onDatabaseChanged,
    required this.onTableSelected,
    this.onShowStructure,
    this.onImport,
    this.onCreateTable,
  });

  @override
  State<TableSidebar> createState() => _TableSidebarState();
}

class _TableSidebarState extends State<TableSidebar> {
  final _filter = TextEditingController();

  List<String> _databases = [];
  List<TableInfo> _tables = [];
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
      // 连接时没指定库：先只列库，等用户在上面选一个
      final tables = widget.database.isEmpty ? <TableInfo>[] : await widget.source.tables(widget.database);
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

  void _browse(String table) => widget.onTableSelected(table);

  /// 建好之后重读清单。选不选中新表由调用方决定（它知道当前标签在什么模式）
  Future<void> _createTable() async {
    final onCreateTable = widget.onCreateTable;
    if (onCreateTable == null) return;
    final created = await onCreateTable(widget.database);
    if (created == null || !mounted) return;
    await _reload();
  }

  static const _createTableItem = PopupMenuItem(
    value: 'create',
    height: 26,
    child: Text('新建表…'),
  );

  /// 没有表可以右键时（空库、过滤后没有匹配），在空白处右键只给「新建表…」
  Future<void> _showBlankMenu(Offset position) async {
    if (widget.onCreateTable == null) return;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: const [_createTableItem],
    );
    if (!mounted) return;
    if (choice == 'create') await _createTable();
  }

  /// 右键菜单，出现在鼠标位置
  Future<void> _showMenu(String table, Offset position) async {
    final onShowStructure = widget.onShowStructure;
    final onImport = widget.onImport;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(value: 'browse', height: 26, child: Text('浏览数据')),
        if (onShowStructure != null)
          const PopupMenuItem(value: 'structure', height: 26, child: Text('查看结构')),
        if (onImport != null)
          const PopupMenuItem(value: 'import', height: 26, child: Text('导入 CSV…')),
        if (widget.onCreateTable != null) ...[const PopupMenuDivider(height: 8), _createTableItem],
      ],
    );
    if (!mounted) return;
    if (choice == 'browse') _browse(table);
    if (choice == 'structure' && onShowStructure != null) onShowStructure(table);
    if (choice == 'import' && onImport != null) onImport(table);
    if (choice == 'create') await _createTable();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleTables;
    final mac = MacColors.of(context);

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: mac.sidebar,
        border: Border(right: BorderSide(color: mac.separator)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            child: _DatabasePicker(
              databases: _databases,
              current: widget.database,
              onChanged: widget.onDatabaseChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: MacSearchField(
              controller: _filter,
              hint: '过滤表名',
              icon: Icons.filter_list,
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (widget.database.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('在上面选一个库', style: TextStyle(fontSize: 12, color: mac.secondaryText)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            // 只在没有行的时候接空白处的右键：行和外层都接右键的话，按住稍久两边都会弹菜单
            child: visible.isEmpty
                ? GestureDetector(
                    key: const ValueKey('sidebar-blank'),
                    behavior: HitTestBehavior.opaque,
                    onSecondaryTapDown: (details) => _showBlankMenu(details.globalPosition),
                    child: const SizedBox.expand(),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 6),
                    itemCount: visible.length,
                    itemExtent: 26,
                    itemBuilder: (context, index) {
                      final table = visible[index];
                      return SidebarItem(
                        icon: table.isView ? Icons.visibility_outlined : Icons.grid_on,
                        iconColor: mac.tableIcon,
                        label: table.name,
                        // InnoDB 的行数是估算值，标个 ~ 免得被当成精确数字
                        trailing: !table.isView && table.estimatedRows > BigInt.zero ? '~${table.estimatedRows}' : null,
                        selected: table.name == widget.selectedTable,
                        onTap: () => _browse(table.name),
                        onSecondaryTap: (position) => _showMenu(table.name, position),
                      );
                    },
                  ),
          ),
          _SidebarFooter(
            count: visible.length,
            total: _tables.length,
            loading: _loading,
            onCreateTable: widget.onCreateTable == null ? null : _createTable,
          ),
        ],
      ),
    );
  }
}

/// 库选择器：看起来像一个带库图标的圆角框，点开是库列表
class _DatabasePicker extends StatelessWidget {
  final List<String> databases;
  final String current;
  final void Function(String database) onChanged;

  const _DatabasePicker({required this.databases, required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    // 当前库可能还没出现在列表里（刚连上、或者没权限列库），先补进去免得下拉崩掉
    final items = databases.contains(current) ? databases : [current, ...databases];

    return SizedBox(
      height: 26,
      child: DropdownButtonFormField<String>(
        // 换了库、换了标签时 initialValue 不会自己更新，靠换 key 重建
        key: ValueKey('database-$current'),
        initialValue: current,
        isDense: true,
        // 库名长了会把侧栏撑破，必须让它自适应宽度再省略
        isExpanded: true,
        iconSize: 16,
        style: TextStyle(fontSize: 13, color: mac.text),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          prefixIcon: Icon(Icons.storage, size: 15, color: mac.databaseIcon),
          prefixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 24),
          fillColor: mac.text.withValues(alpha: 0.06),
          enabledBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(6)),
            borderSide: BorderSide(color: mac.separator),
          ),
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
      ),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  final int count;
  final int total;
  final bool loading;
  final VoidCallback? onCreateTable;

  const _SidebarFooter({required this.count, required this.total, required this.loading, required this.onCreateTable});

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    return Container(
      height: 24,
      padding: const EdgeInsets.only(left: 4, right: 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: mac.separator))),
      child: Row(
        children: [
          if (onCreateTable != null)
            Tooltip(
              message: '新建表…',
              child: InkWell(
                onTap: onCreateTable,
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(width: 22, height: 20, child: Icon(Icons.add, size: 14, color: mac.secondaryText)),
              ),
            ),
          const SizedBox(width: 4),
          Text(
            count == total ? '$total 张表' : '$count / $total 张表',
            style: TextStyle(fontSize: 11, color: mac.secondaryText),
          ),
          const Spacer(),
          // 同 result_grid：无限动画会把 pumpAndSettle 卡死
          if (loading) Text('加载中…', style: TextStyle(fontSize: 11, color: mac.secondaryText)),
        ],
      ),
    );
  }
}
