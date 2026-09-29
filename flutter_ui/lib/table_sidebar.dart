import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data_source.dart';
import 'export_dialog.dart';
import 'mac_widgets.dart';
import 'src/rust/api/db.dart' show ExportFormat;
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

  /// 右键「导入…」。CSV 需要目标表；SQL 按文件中的语句执行，table 可为 null。
  /// 返回是否执行或提交了导入，侧栏据此重读清单。
  final Future<bool> Function(String? table)? onImport;

  /// 右键菜单里的「新建表…」，参数是当前库。返回建好的表名，侧栏据此重读并选中；
  /// 取消返回 null。null 就不给这一项
  final Future<String?> Function(String database)? onCreateTable;

  /// 右键「在新标签中打开」。null 就不给这一项
  final void Function(String table)? onOpenInNewTab;

  /// 改名、复制、删除、清空执行成功之后通知外面：标签要跟着换表名、清掉已删的表、重读数据和补全目录
  final void Function(String table, TableAction action)? onTableAction;

  /// 选导出文件的保存位置，返回 null 表示取消。不传就弹系统保存对话框，测试里换掉
  final Future<String?> Function(String suggestedName)? pickSavePath;

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
    this.pickSavePath,
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

  /// 正在做的耗时操作（比如导出），显示在底栏
  String? _busy;

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

  static const _createDatabaseItem = PopupMenuItem(
    value: 'create-database',
    height: 26,
    child: Text('新建数据库…'),
  );

  Future<void> _import(String? table) async {
    final changed = await widget.onImport?.call(table) ?? false;
    if (changed && mounted) await _reload();
  }

  /// 没有表可以右键时（空库、过滤后没有匹配），在空白处右键只给「新建库…」「新建表…」
  Future<void> _showBlankMenu(Offset position) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        _createDatabaseItem,
        if (widget.onCreateTable != null && widget.database.isNotEmpty) _createTableItem,
        if (widget.onImport != null) const PopupMenuItem(value: 'import', height: 26, child: Text('导入…')),
      ],
    );
    if (!mounted) return;
    if (choice == 'create-database') await _createDatabase();
    if (choice == 'create') await _createTable();
    if (choice == 'import') await _import(null);
  }

  /// 右键菜单，出现在鼠标位置。分组照 Querious：打开、改名复制、删除、复制文本、导入统计、新建
  Future<void> _showMenu(TableInfo info, Offset position) async {
    final table = info.name;
    final isView = info.isView;
    final onShowStructure = widget.onShowStructure;
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
        if (widget.onImport != null) const PopupMenuItem(value: 'import', height: 26, child: Text('导入…')),
        const PopupMenuItem(value: 'export', height: 26, child: Text('导出…')),
        if (!isView) const PopupMenuItem(value: 'count', height: 26, child: Text('统计行数')),
        if (!isView)
          const PopupMenuItem(
            value: 'operations',
            height: 26,
            child: Row(children: [Expanded(child: Text('表操作')), Icon(Icons.chevron_right, size: 16)]),
          ),
        const PopupMenuDivider(height: 8),
        _createDatabaseItem,
        if (widget.onCreateTable != null) _createTableItem,
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
        await _import(isView ? null : table);
      case 'export':
        await _export(table);
      case 'count':
        await _countRows(table);
      case 'operations':
        await _showOperations(table, at);
      case 'create-database':
        await _createDatabase();
      case 'create':
        await _createTable();
    }
  }

  /// 导出整张表：选项 → 保存位置 → core 从库里逐行读写。不经过结果网格，不受行数上限限制
  Future<void> _export(String table) async {
    final choice = await showExportDialog(
      context,
      allRowsLabel: '整张表（不受行数上限限制）',
      selectionLabel: null,
      suggestedTable: '',
    );
    if (choice == null || !mounted) return;
    final extension = choice.options.format == ExportFormat.csv ? 'csv' : 'sql';
    final pickSavePath = widget.pickSavePath ?? pickExportPath;
    final path = await pickSavePath('$table.$extension');
    if (path == null || !mounted) return;

    final database = widget.database;
    setState(() => _busy = '正在导出 $table…');
    final int written;
    try {
      written = await widget.source.exportTable(database, table, path, choice.options);
    } catch (e) {
      if (mounted) setState(() => _error = '导出 $table 失败：$e');
      return;
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出完成'),
        content: SelectableText('已把 $table 的 $written 行导出到\n$path'),
        actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('好'))],
      ),
    );
  }

  /// 新建库：选项 → 预览 DDL → 执行。建好后切到新库
  Future<void> _createDatabase() async {
    final DatabaseOptions options;
    try {
      options = await widget.source.databaseOptions();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    final input = await showDialog<({String name, String charset, String collation})>(
      context: context,
      builder: (context) => _CreateDatabaseDialog(options: options),
    );
    if (input == null || !mounted) return;

    final AlterPlan plan;
    try {
      plan = await widget.source.previewCreateDatabase(input.name, input.charset, input.collation);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    final applied = await showDdlPreview(
      context,
      plan: plan,
      cancelLabel: '取消',
      apply: () => widget.source.applyCreateDatabase(input.name, input.charset, input.collation, plan.statements),
    );
    if (!applied || !mounted) return;
    widget.onDatabaseChanged(input.name);
    await _reload();
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
            status: _busy ?? (_loading ? '加载中…' : null),
            onCreateTable: widget.onCreateTable == null ? null : _createTable,
          ),
        ],
      ),
    );
  }
}

/// 库选择器：看起来像一个带库图标的圆角框，点开是库列表
/// 选库：按钮下方弹出带过滤框的列表。库多的时候 PopupMenuButton 会按当前项对齐，整个菜单被推到窗口顶上，
/// 所以自己画：固定挂在按钮下面、限高滚动、打开时滚到当前库，输入即过滤，回车选第一个
class _DatabasePicker extends StatefulWidget {
  final List<String> databases;
  final String current;
  final void Function(String database) onChanged;

  const _DatabasePicker({required this.databases, required this.current, required this.onChanged});

  @override
  State<_DatabasePicker> createState() => _DatabasePickerState();
}

class _DatabasePickerState extends State<_DatabasePicker> {
  static const _rowHeight = 24.0;
  static const _maxListHeight = 360.0;

  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();
  final _tapGroup = Object();
  ScrollController? _scroll;

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    _scroll?.dispose();
    super.dispose();
  }

  List<String> get _visible {
    final keyword = _filter.text.trim().toLowerCase();
    if (keyword.isEmpty) return widget.databases;

    final matched = <String>[];
    for (final database in widget.databases) {
      if (database.toLowerCase().contains(keyword)) matched.add(database);
    }
    return matched;
  }

  void _open() {
    _filter.clear();
    // 当前库放在列表第三行左右，上面留点上下文
    final index = widget.databases.indexOf(widget.current);
    final offset = index < 0 ? 0.0 : (index - 2).clamp(0, index) * _rowHeight;
    _scroll?.dispose();
    _scroll = ScrollController(initialScrollOffset: offset);
    _portal.show();
    _filterFocus.requestFocus();
    setState(() {});
  }

  void _close() {
    _portal.hide();
    setState(() {});
  }

  void _pick(String database) {
    _close();
    if (database != widget.current) widget.onChanged(database);
  }

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final hasCurrent = widget.current.isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) => OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => _popover(mac, constraints.maxWidth),
        child: CompositedTransformTarget(
          link: _link,
          child: TapRegion(
            groupId: _tapGroup,
            child: GestureDetector(
              key: const ValueKey('database-picker'),
              onTap: () => _portal.isShowing ? _close() : _open(),
              child: Container(
                height: 24,
                padding: const EdgeInsets.only(left: 8, right: 4),
                decoration: BoxDecoration(
                  color: mac.control,
                  border: Border.all(color: mac.controlBorder),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  children: [
                    Icon(Icons.storage, size: 14, color: mac.databaseIcon),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        hasCurrent ? widget.current : '选择数据库',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: hasCurrent ? mac.text : mac.tertiaryText),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.unfold_more, size: 14, color: mac.secondaryText),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _popover(MacColors mac, double width) {
    final visible = _visible;
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.bottomLeft,
      offset: const Offset(0, 2),
      child: Align(
        alignment: Alignment.topLeft,
        child: TapRegion(
          groupId: _tapGroup,
          onTapOutside: (_) => _close(),
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
            child: Material(
              color: mac.content,
              elevation: 8,
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: SizedBox(
                        height: 26,
                        child: TextField(
                          key: const ValueKey('database-picker-filter'),
                          controller: _filter,
                          focusNode: _filterFocus,
                          style: const TextStyle(fontSize: 13),
                          decoration: InputDecoration(
                            hintText: '过滤库名',
                            prefixIcon: Icon(Icons.search, size: 15, color: mac.tertiaryText),
                            prefixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 24),
                            contentPadding: const EdgeInsets.symmetric(vertical: 5),
                          ),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) {
                            if (visible.isNotEmpty) _pick(visible.first);
                          },
                        ),
                      ),
                    ),
                    Divider(height: 1, color: mac.separator),
                    if (visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text('没有匹配的库', style: TextStyle(fontSize: 12, color: mac.secondaryText)),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: _maxListHeight),
                        child: ListView.builder(
                          // 过滤后列表短了，旧的滚动位置会越界，换个新的从头开始
                          controller: _filter.text.isEmpty ? _scroll : null,
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemExtent: _rowHeight,
                          itemCount: visible.length,
                          itemBuilder: (context, index) => _row(mac, visible[index]),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(MacColors mac, String database) {
    return InkWell(
      onTap: () => _pick(database),
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 12),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: database == widget.current ? Icon(Icons.check, size: 13, color: mac.text) : null,
            ),
            Expanded(
              child: Text(database, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
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
  /// 右下角的状态文字，null 不显示
  final String? status;
  final VoidCallback? onCreateTable;

  const _SidebarFooter({required this.count, required this.total, required this.status, required this.onCreateTable});

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
          if (status != null) Text(status!, style: TextStyle(fontSize: 11, color: mac.secondaryText)),
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

/// 新建库：库名、字符集、排序规则。默认值用服务器的，排序规则跟着字符集换
class _CreateDatabaseDialog extends StatefulWidget {
  final DatabaseOptions options;

  const _CreateDatabaseDialog({required this.options});

  @override
  State<_CreateDatabaseDialog> createState() => _CreateDatabaseDialogState();
}

class _CreateDatabaseDialogState extends State<_CreateDatabaseDialog> {
  final _name = TextEditingController();
  late String _charset = widget.options.defaultCharset;
  late String _collation = widget.options.defaultCollation;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  CharsetInfo? get _charsetInfo {
    for (final info in widget.options.charsets) {
      if (info.name == _charset) return info;
    }
    return null;
  }

  /// 换字符集时排序规则换成它的默认值；换回服务器默认字符集时用服务器的默认排序规则
  void _changeCharset(String charset) {
    setState(() {
      _charset = charset;
      if (charset == widget.options.defaultCharset) {
        _collation = widget.options.defaultCollation;
      } else {
        _collation = _charsetInfo!.defaultCollation;
      }
    });
  }

  /// 库名原样交给 core，不在这里修剪
  void _submit() => Navigator.of(context).pop((name: _name.text, charset: _charset, collation: _collation));

  @override
  Widget build(BuildContext context) {
    final collations = _charsetInfo?.collations ?? const <String>[];
    return AlertDialog(
      title: const Text('新建数据库'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FormRow(
              label: '库名',
              labelWidth: 80,
              child: TextField(
                key: const ValueKey('database-name-field'),
                controller: _name,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                onSubmitted: (_) => _submit(),
              ),
            ),
            FormRow(
              label: '字符集',
              labelWidth: 80,
              child: Align(
                alignment: Alignment.centerLeft,
                child: MacPopupButton<String>(
                  key: const ValueKey('database-charset'),
                  value: _charset,
                  items: {for (final info in widget.options.charsets) info.name: info.name},
                  onChanged: _changeCharset,
                ),
              ),
            ),
            FormRow(
              label: '排序规则',
              labelWidth: 80,
              child: Align(
                alignment: Alignment.centerLeft,
                child: MacPopupButton<String>(
                  key: const ValueKey('database-collation'),
                  value: _collation,
                  items: {for (final collation in collations) collation: collation},
                  onChanged: (collation) => setState(() => _collation = collation),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('预览')),
      ],
    );
  }
}
