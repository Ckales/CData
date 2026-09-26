import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data_source.dart';
import 'mac_widgets.dart';
import 'src/rust/api/schema.dart';
import 'structure_editor.dart' show showDdlPreview;
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

  /// 右键「在新标签中打开」。null 就不给这一项
  final void Function(String table)? onOpenInNewTab;

  /// 改名、复制、删除、清空执行成功之后通知外面：标签要跟着换表名、清掉已删的表、重读数据和补全目录
  final void Function(String table, TableAction action)? onTableAction;

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
    this.onOpenInNewTab,
    this.onTableAction,
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

  /// 右键菜单，出现在鼠标位置。分组照 Querious：打开、改名复制、删除、复制文本、导入统计、新建
  Future<void> _showMenu(TableInfo info, Offset position) async {
    final table = info.name;
    final isView = info.isView;
    final onShowStructure = widget.onShowStructure;
    final onImport = widget.onImport;
    final onOpenInNewTab = widget.onOpenInNewTab;
    final at = RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy);
    final choice = await showMenu<String>(
      context: context,
      position: at,
      items: [
        const PopupMenuItem(value: 'browse', height: 26, child: Text('浏览数据')),
        if (onOpenInNewTab != null) const PopupMenuItem(value: 'new-tab', height: 26, child: Text('在新标签中打开')),
        const PopupMenuDivider(height: 8),
        const PopupMenuItem(value: 'rename', height: 26, child: Text('重命名…')),
        // 视图没法 CREATE TABLE … LIKE，复制请拿建表语句改
        if (!isView) const PopupMenuItem(value: 'duplicate', height: 26, child: Text('复制表…')),
        const PopupMenuDivider(height: 8),
        const PopupMenuItem(value: 'drop', height: 26, child: Text('删除…')),
        const PopupMenuDivider(height: 8),
        const PopupMenuItem(value: 'copy-name', height: 26, child: Text('复制名称')),
        const PopupMenuItem(value: 'copy-create', height: 26, child: Text('复制建表语句')),
        if (!isView) const PopupMenuItem(value: 'copy-insert', height: 26, child: Text('复制 INSERT 语句')),
        const PopupMenuDivider(height: 8),
        if (onShowStructure != null) const PopupMenuItem(value: 'structure', height: 26, child: Text('查看结构')),
        if (onImport != null && !isView) const PopupMenuItem(value: 'import', height: 26, child: Text('导入 CSV…')),
        if (!isView) const PopupMenuItem(value: 'count', height: 26, child: Text('统计行数')),
        if (!isView)
          const PopupMenuItem(
            value: 'operations',
            height: 26,
            child: Row(children: [Expanded(child: Text('表操作')), Icon(Icons.chevron_right, size: 16)]),
          ),
        if (widget.onCreateTable != null) ...[const PopupMenuDivider(height: 8), _createTableItem],
      ],
    );
    if (!mounted || choice == null) return;
    setState(() => _error = null);
    switch (choice) {
      case 'browse':
        _browse(table);
      case 'new-tab':
        onOpenInNewTab?.call(table);
      case 'rename':
        await _rename(table);
      case 'duplicate':
        await _duplicate(table);
      case 'drop':
        await _runAction(table, const TableAction.drop());
      case 'copy-name':
        await Clipboard.setData(ClipboardData(text: table));
      case 'copy-create':
        await _copy(() async => (await widget.source.structure(widget.database, table)).createSql);
      case 'copy-insert':
        await _copy(() => widget.source.insertTemplate(widget.database, table));
      case 'structure':
        onShowStructure?.call(table);
      case 'import':
        onImport?.call(table);
      case 'count':
        await _countRows(table);
      case 'operations':
        await _showOperations(table, at);
      case 'create':
        await _createTable();
    }
  }

  /// 「表操作」二级菜单，在同一个位置弹出
  Future<void> _showOperations(String table, RelativeRect at) async {
    final choice = await showMenu<Object>(
      context: context,
      position: at,
      items: const [
        PopupMenuItem(value: 'truncate', height: 26, child: Text('清空表…')),
        PopupMenuDivider(height: 8),
        PopupMenuItem(value: Maintenance.analyze, height: 26, child: Text('分析表')),
        PopupMenuItem(value: Maintenance.check, height: 26, child: Text('检查表')),
        PopupMenuItem(value: Maintenance.optimize, height: 26, child: Text('优化表')),
        PopupMenuItem(value: Maintenance.repair, height: 26, child: Text('修复表')),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'truncate') await _runAction(table, const TableAction.truncate());
    if (choice is Maintenance) await _maintain(table, choice);
  }

  Future<void> _copy(Future<String> Function() read) async {
    try {
      final text = await read();
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _rename(String table) async {
    final result = await _askName(title: '重命名 $table', initial: table, confirm: '预览');
    if (result == null || !mounted) return;
    await _runAction(table, TableAction.rename(newName: result.name));
  }

  Future<void> _duplicate(String table) async {
    final result = await _askName(title: '复制表 $table', initial: '${table}_copy', confirm: '预览', askData: true);
    if (result == null || !mounted) return;
    await _runAction(table, TableAction.duplicate(newName: result.name, withData: result.withData));
  }

  /// 预览 → 确认框 → 执行。成功后重读清单并通知外面
  Future<void> _runAction(String table, TableAction action) async {
    final database = widget.database;
    final AlterPlan plan;
    try {
      plan = await widget.source.previewTableAction(database, table, action);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    final applied = await showDdlPreview(
      context,
      plan: plan,
      cancelLabel: '取消',
      apply: () => widget.source.applyTableAction(database, table, action, plan.statements),
    );
    if (!applied || !mounted) return;
    widget.onTableAction?.call(table, action);
    await _reload();
  }

  Future<void> _countRows(String table) async {
    final int count;
    try {
      count = await widget.source.countRows(widget.database, table);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(table),
        content: Text('共 $count 行（COUNT(*) 精确值）'),
        actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('好'))],
      ),
    );
  }

  Future<void> _maintain(String table, Maintenance op) async {
    final List<MaintenanceMessage> messages;
    try {
      messages = await widget.source.runMaintenance(widget.database, table, op);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    final title = switch (op) {
      Maintenance.analyze => '分析表',
      Maintenance.check => '检查表',
      Maintenance.optimize => '优化表',
      Maintenance.repair => '修复表',
    };
    await showDialog<void>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text('$title $table'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (messages.isEmpty) const Text('MySQL 没有返回消息'),
                for (final message in messages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: SelectableText(
                      '${message.msgType}：${message.text}',
                      style: TextStyle(
                        fontSize: 12,
                        // Msg_type 是 status / error / info / note / warning
                        color: message.msgType == 'error' ? scheme.error : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('好'))],
        );
      },
    );
  }

  /// 问一个新名字。名字原样交给 core，不在这里修剪；askData 时多一个「同时复制数据」
  Future<({String name, bool withData})?> _askName({
    required String title,
    required String initial,
    required String confirm,
    bool askData = false,
  }) {
    return showDialog<({String name, bool withData})>(
      context: context,
      builder: (context) => _NameDialog(title: title, initial: initial, confirm: confirm, askData: askData),
    );
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
                        onSecondaryTap: (position) => _showMenu(table, position),
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
    // 当前库可能还没出现在列表里（刚连上、或者没权限列库），先补进去，否则按钮只显示占位符
    final items = databases.contains(current) ? databases : [current, ...databases];

    return MacPopupButton<String>(
      value: current,
      items: {for (final database in items) database: database},
      expand: true,
      leading: Icon(Icons.storage, size: 14, color: mac.databaseIcon),
      onChanged: onChanged,
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

class _NameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String confirm;
  final bool askData;

  const _NameDialog({required this.title, required this.initial, required this.confirm, required this.askData});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
  bool _withData = true;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop((name: _name.text, withData: _withData));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('table-name-field'),
              controller: _name,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(labelText: '新名字'),
              onSubmitted: (_) => _submit(),
            ),
            if (widget.askData)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _withData,
                onChanged: (value) => setState(() => _withData = value ?? false),
                title: const Text('同时复制数据', style: TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: Text(widget.confirm)),
      ],
    );
  }
}
