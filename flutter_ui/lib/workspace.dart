import 'package:file_selector/file_selector.dart' show XTypeGroup, openFile;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data_source.dart';
import 'import_dialog.dart';
import 'mac_widgets.dart';
import 'query_tab.dart';
import 'server_source.dart';
import 'server_status.dart';
import 'sql_library.dart';
import 'sql_import_dialog.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/editor.dart';
import 'src/rust/api/options.dart';
import 'src/rust/api/schema.dart';
import 'structure_editor.dart';
import 'structure_view.dart';
import 'table_sidebar.dart';
import 'theme.dart';
import 'user_admin.dart';
import 'user_source.dart';

/// 工具栏上的四个模式，和 Querious 一样
enum WorkspaceMode { content, structure, query, server }

/// 一条打开的连接（Querious 的一个窗口）：一个侧栏会话 + 若干标签。
///
/// 侧栏会话给侧栏、结构、服务器、用户、导入、补全用；每个标签另有自己的查询会话。
class Workspace {
  final int id;
  final String name;
  final ConnectionConfig config;
  final BigInt schemaId;

  // 数据源随会话建一次，每次重绘都新建的话侧栏会以为换了库，重读一遍
  final RustSchemaSource schema;
  final RustServerSource server;
  final RustUserSource users;
  final RustImportSource imports;

  final List<WorkspaceTab> tabs = [];
  int active = 0;

  // 标签栏里各条连接的标签排在一起，编号全局唯一
  static int _nextTabNumber = 1;

  /// 补全目录现在装的是哪个库。一个会话只缓存一个库的目录，切到别的库的标签时要重读
  String? catalogDatabase;

  Workspace({required this.id, required this.name, required this.config, required this.schemaId})
    : schema = RustSchemaSource(schemaId),
      server = RustServerSource(schemaId),
      users = RustUserSource(schemaId),
      imports = RustImportSource(schemaId);

  WorkspaceTab get activeTab => tabs[active];

  String get subtitle => '${config.user}@${config.host}:${config.port}';

  /// 这个标签用的连接参数：和工作区一样，只是库换成标签自己选的
  ConnectionConfig configFor(String database) {
    return ConnectionConfig(
      host: config.host,
      port: config.port,
      user: config.user,
      password: config.password,
      database: database.isEmpty ? null : database,
      options: config.options,
      sshSecrets: config.sshSecrets,
      savedId: config.savedId,
    );
  }

  int takeTabNumber() => _nextTabNumber++;
}

/// 一个标签：自己的模式、自己选的库和表。内容模式和查询模式各有一个会话，一个会话只放一份结果
class WorkspaceTab {
  final int id;
  WorkspaceMode mode;
  String database;
  String? table;

  /// 查询模式里最近跑过的 SQL 的开头，当标题用
  String? queryTitle;

  /// 进过的模式才建界面：服务器页一建就会去查进程列表，没点过就不查
  final Set<WorkspaceMode> visited;

  final contentKey = GlobalKey<QueryTabState>();
  final queryKey = GlobalKey<QueryTabState>();
  late final RustQueryRunner contentRunner;
  late final RustQueryRunner queryRunner;

  WorkspaceTab({required this.id, required this.mode, required this.database, this.table}) : visited = {mode};

  String get title {
    final table = this.table;
    if (mode == WorkspaceMode.query) return queryTitle ?? '查询';
    if (mode == WorkspaceMode.server) return '服务器';
    if (table != null) return '$database.$table';
    return database.isEmpty ? '未选库' : database;
  }

  Future<void> close() async {
    await contentRunner.close();
    await queryRunner.close();
  }
}

/// 工作区的界面：工具栏 + 侧栏 + 标签 + 当前模式的内容
class WorkspaceView extends StatefulWidget {
  final Workspace workspace;

  /// 窗口里全部连接，按顺序，包括自己。标签栏把它们的标签排成一排，和 Querious 一样一个标签一条连接
  final List<Workspace> all;

  /// 切到别的连接的某个标签
  final void Function(Workspace workspace, int tab) onSwitch;

  /// 关掉别的连接的某个标签
  final void Function(Workspace workspace, int tab) onCloseTab;
  final VoidCallback onNewConnection;
  final VoidCallback onDisconnect;
  final VoidCallback onPreferences;

  final BigInt Function() maxRows;
  final double editorFontSize;
  final Future<bool> Function(HostKeyIssue issue) confirmHostKey;

  const WorkspaceView({
    super.key,
    required this.workspace,
    required this.all,
    required this.onSwitch,
    required this.onCloseTab,
    required this.onNewConnection,
    required this.onDisconnect,
    required this.onPreferences,
    required this.maxRows,
    required this.editorFontSize,
    required this.confirmHostKey,
  });

  @override
  State<WorkspaceView> createState() => WorkspaceViewState();
}

class WorkspaceViewState extends State<WorkspaceView> {
  static const _library = RustSqlLibrary();

  /// 快捷键挂在这个节点上。切标签时旧标签被 IndexedStack 设成不可聚焦，焦点会退到路由那一层、
  /// 跑到快捷键外面去，所以每次换标签都把焦点收回这里
  final _pageFocus = FocusNode(debugLabel: 'workspace');

  String? _error;
  Offset _titleTapPosition = Offset.zero;

  Workspace get _ws => widget.workspace;
  WorkspaceTab get _tab => _ws.activeTab;

  @override
  void initState() {
    super.initState();
    if (_ws.tabs.isEmpty) _addTab(database: _ws.config.database ?? '');
    _ensureCatalog(_tab);
  }

  @override
  void dispose() {
    _pageFocus.dispose();
    super.dispose();
  }

  void _addTab({required String database, String? table, WorkspaceMode mode = WorkspaceMode.content}) {
    final tab = WorkspaceTab(id: _ws.takeTabNumber(), mode: mode, database: database, table: table);
    tab.contentRunner = RustQueryRunner(
      readConfig: () => _ws.configFor(tab.database),
      maxRows: widget.maxRows,
      confirmHostKey: widget.confirmHostKey,
    );
    tab.queryRunner = RustQueryRunner(
      readConfig: () => _ws.configFor(tab.database),
      maxRows: widget.maxRows,
      confirmHostKey: widget.confirmHostKey,
    );
    _ws.tabs.add(tab);
    _ws.active = _ws.tabs.length - 1;
    _keepShortcutsAlive();
    if (table != null) _loadTable(tab);
  }

  /// 新标签沿用当前标签的库、表和模式。菜单栏的「新建已连接标签」也调这个
  void duplicateTab() {
    final current = _tab;
    setState(() => _addTab(database: current.database, table: current.table, mode: current.mode));
  }

  /// 关这条连接的最后一个标签就是断开它；整个窗口只剩这一个标签时不给关
  Future<void> closeTab(int index) async {
    if (_ws.tabs.length == 1) {
      if (widget.all.length > 1) widget.onDisconnect();
      return;
    }
    final tab = _ws.tabs[index];
    setState(() {
      _ws.tabs.removeAt(index);
      _ws.active = _ws.active.clamp(0, _ws.tabs.length - 1);
    });
    _keepShortcutsAlive();
    await tab.close();
  }

  void selectTab(int index) {
    if (index < 0 || index >= _ws.tabs.length) return;
    setState(() => _ws.active = index);
    _keepShortcutsAlive();
    _ensureCatalog(_tab);
  }

  /// 标签栏上的全部标签：（连接，这条连接里的第几个标签）
  List<(Workspace, int)> get _allTabs => [
    for (final workspace in widget.all)
      for (var i = 0; i < workspace.tabs.length; i++) (workspace, i),
  ];

  void _selectAt(int index) {
    final entries = _allTabs;
    if (index < 0 || index >= entries.length) return;
    final (workspace, tab) = entries[index];
    if (workspace == _ws) {
      selectTab(tab);
    } else {
      widget.onSwitch(workspace, tab);
    }
  }

  void _closeAt(int index) {
    final (workspace, tab) = _allTabs[index];
    if (workspace == _ws) {
      closeTab(tab);
    } else {
      widget.onCloseTab(workspace, tab);
    }
  }

  /// 等这一帧把旧标签设成不可聚焦之后再收回焦点
  void _keepShortcutsAlive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pageFocus.requestFocus();
    });
  }

  void _setMode(WorkspaceMode mode) {
    setState(() {
      _tab.mode = mode;
      _tab.visited.add(mode);
    });
  }

  /// 侧栏点表：当前标签换成这张表。在服务器模式里点表就回到内容模式
  void _openTable(String table) {
    final tab = _tab;
    setState(() {
      tab.table = table;
      if (tab.mode == WorkspaceMode.server || tab.mode == WorkspaceMode.query) tab.mode = WorkspaceMode.content;
      tab.visited.add(tab.mode);
    });
    _loadTable(tab);
  }

  /// 内容模式的网格跑 SELECT * FROM 表。要等内容页建好（第一次进内容模式时它还不在树上）
  void _loadTable(WorkspaceTab tab) {
    final table = tab.table;
    if (table == null) return;
    tab.visited.add(WorkspaceMode.content);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final sql = await browseSql(table: table);
      await tab.contentKey.currentState?.runSql(sql);
    });
  }

  /// 换库：这个标签的两个会话按新库重开，选中的表清掉
  Future<void> _switchDatabase(String database) async {
    final tab = _tab;
    setState(() {
      tab.database = database;
      tab.table = null;
    });
    await tab.contentKey.currentState?.reset();
    await tab.queryKey.currentState?.reset();
    await tab.contentRunner.close();
    await tab.queryRunner.close();
    await _ensureCatalog(tab);
  }

  /// 补全目录跟着当前标签的库走
  Future<void> _ensureCatalog(WorkspaceTab tab, {bool force = false}) async {
    final database = tab.database;
    if (database.isEmpty) return;
    if (!force && _ws.catalogDatabase == database) return;
    try {
      await loadCatalog(sessionId: _ws.schemaId, database: database);
      _ws.catalogDatabase = database;
    } catch (e) {
      if (mounted) setState(() => _error = '读取补全目录失败：$e');
    }
  }

  /// 补全走工作区的侧栏会话，它缓存着目录。目录不是这个库的就不补，免得给出别的库的表
  Completion? _complete(WorkspaceTab tab, String sql, int cursor) {
    if (_ws.catalogDatabase != tab.database) return null;
    try {
      return completeSql(sessionId: _ws.schemaId, sql: sql, cursor: cursor);
    } catch (e) {
      // 补全失败不该打断输入，记下来方便排查
      debugPrint('补全失败（会话 ${_ws.schemaId}，光标 $cursor）：$e');
      return null;
    }
  }

  void _retitle(WorkspaceTab tab, String sql) {
    final firstLine = sql.trim().split('\n').first;
    final title = firstLine.length > 24 ? '${firstLine.substring(0, 24)}…' : firstLine;
    setState(() => tab.queryTitle = title.isEmpty ? null : title);
  }

  Future<void> _showStructureOf(String table) async {
    setState(() {
      _tab.table = table;
      _tab.mode = WorkspaceMode.structure;
      _tab.visited.add(WorkspaceMode.structure);
    });
  }

  Future<String?> _createTable(String database) async {
    final created = await showTableCreator(context, source: _ws.schema, database: database);
    if (created == null) return null;
    // ponytail: 建表、改表之后整库重读一遍目录，几万列的大库再改成增量
    await _ensureCatalog(_tab, force: true);
    _openTable(created);
    return created;
  }

  /// 侧栏改名、删除、清空、复制表成功之后：显示这张表的标签跟着换表名、清掉已删的表、
  /// 重新查数据；表清单变了，补全目录也重读
  void _afterTableAction(String table, TableAction action) {
    final database = _tab.database;
    final reload = <WorkspaceTab>[];
    setState(() {
      for (final tab in _ws.tabs) {
        if (tab.database != database || tab.table != table) continue;
        switch (action) {
          case TableAction_Rename(:final newName):
            tab.table = newName;
            reload.add(tab);
          case TableAction_Drop():
            tab.table = null;
          case TableAction_Truncate():
            reload.add(tab);
          case TableAction_Duplicate():
            break;
        }
      }
    });
    for (final tab in reload) {
      _loadTable(tab);
    }
    _ensureCatalog(_tab, force: true);
  }

  Future<void> _showConnectionMenu(Offset position) async {
    final others = [
      for (final workspace in widget.all)
        if (workspace != _ws) workspace,
    ];
    final choice = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        for (final other in others)
          PopupMenuItem(value: other, height: 26, child: Text('切换到 ${other.name}')),
        if (others.isNotEmpty) const PopupMenuDivider(height: 8),
        const PopupMenuItem(value: 'new', height: 26, child: Text('新建连接…')),
        PopupMenuItem(value: 'disconnect', height: 26, child: Text('断开 ${_ws.name}')),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice is Workspace) widget.onSwitch(choice, choice.active);
    if (choice == 'new') widget.onNewConnection();
    if (choice == 'disconnect') widget.onDisconnect();
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    const digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
    ];
    final entries = _allTabs;
    final count = entries.length;
    final current = entries.indexOf((_ws, _ws.active));
    return {
      // 和 Querious 一样：⌘T 开新连接，⇧⌘T 在当前连接上开新标签
      commandKey(LogicalKeyboardKey.keyT): widget.onNewConnection,
      SingleActivator(LogicalKeyboardKey.keyT, meta: _isMac, control: !_isMac, shift: true): duplicateTab,
      commandKey(LogicalKeyboardKey.keyW): () => closeTab(_ws.active),
      commandKey(LogicalKeyboardKey.comma): widget.onPreferences,
      const SingleActivator(LogicalKeyboardKey.tab, control: true): () => _selectAt((current + 1) % count),
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () =>
          _selectAt((current - 1 + count) % count),
      for (var i = 0; i < digits.length; i++) commandKey(digits[i]): () => _selectAt(i),
      // 和浏览器一样，9 是最后一个
      commandKey(LogicalKeyboardKey.digit9): () => _selectAt(count - 1),
    };
  }

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final tab = _tab;
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        focusNode: _pageFocus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: mac.content,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildToolbar(mac, tab),
              if (_error != null) _WorkspaceError(message: _error!, onClose: () => setState(() => _error = null)),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TableSidebar(
                      source: _ws.schema,
                      database: tab.database,
                      selectedTable: tab.table,
                      onDatabaseChanged: _switchDatabase,
                      onTableSelected: _openTable,
                      onShowStructure: _showStructureOf,
                      onCreateTable: _createTable,
                      onOpenInNewTab: (table) => setState(() => _addTab(database: tab.database, table: table)),
                      onTableAction: _afterTableAction,
                      onImport: (table) async {
                        final file = await openFile(acceptedTypeGroups: const [
                          XTypeGroup(label: 'CSV / SQL', extensions: ['csv', 'tsv', 'txt', 'sql']),
                        ]);
                        if (file == null || !mounted) return false;

                        final path = file.path;
                        final extension = path.split('.').last.toLowerCase();
                        final bool changed;
                        if (extension == 'sql') {
                          changed = await showSqlImportDialog(
                            this.context,
                            sessionId: _ws.schemaId,
                            database: tab.database,
                            initialPath: path,
                          );
                          if (changed && mounted) await _ensureCatalog(tab, force: true);
                        } else if (extension == 'csv' || extension == 'tsv' || extension == 'txt') {
                          if (table == null || tab.database.isEmpty) {
                            setState(() => _error = '导入 CSV 请先在左侧右键选择目标表');
                            return false;
                          }
                          // CSV 导入用侧栏会话的独占连接，不占查询标签的会话。
                          changed = await showImportDialog(
                            this.context,
                            source: _ws.imports,
                            database: tab.database,
                            table: table,
                            initialPath: path,
                          );
                        } else {
                          setState(() => _error = '只支持 CSV、TSV、TXT 或 SQL 文件');
                          return false;
                        }
                        if (changed && mounted && tab.mode == WorkspaceMode.content) _loadTable(tab);
                        return changed;
                      },
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          MacTabStrip(
                            tabs: [
                              for (final (workspace, index) in _allTabs)
                                MacTab(
                                  key: ValueKey('tab-${workspace.tabs[index].id}'),
                                  title: workspace.tabs[index].title,
                                  tooltip: '${workspace.name} · ${workspace.tabs[index].title}',
                                ),
                            ],
                            active: _allTabs.indexOf((_ws, _ws.active)),
                            onSelect: _selectAt,
                            onClose: _closeAt,
                            onAdd: duplicateTab,
                            addTooltip: '新标签（${_isMac ? '⇧⌘T' : 'Ctrl+Shift+T'}）',
                          ),
                          Expanded(
                            // 不在前台的标签也留着，切回来结果、编辑器内容、滚动位置都还在
                            child: IndexedStack(
                              index: _ws.active,
                              children: [for (final item in _ws.tabs) _buildTabBody(item)],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(MacColors mac, WorkspaceTab tab) {
    return MacToolbar(
      children: [
        ToolbarButton(
          key: const ValueKey('mode-content'),
          icon: Icons.grid_on,
          tooltip: '内容',
          selected: tab.mode == WorkspaceMode.content,
          onPressed: () => _setMode(WorkspaceMode.content),
        ),
        ToolbarButton(
          key: const ValueKey('mode-structure'),
          icon: Icons.construction_outlined,
          tooltip: '结构',
          selected: tab.mode == WorkspaceMode.structure,
          onPressed: () => _setMode(WorkspaceMode.structure),
        ),
        ToolbarButton(
          key: const ValueKey('mode-query'),
          icon: Icons.manage_search,
          tooltip: '查询',
          selected: tab.mode == WorkspaceMode.query,
          onPressed: () => _setMode(WorkspaceMode.query),
        ),
        ToolbarButton(
          key: const ValueKey('mode-server'),
          icon: Icons.dns_outlined,
          tooltip: '服务器：进程、变量、用户',
          selected: tab.mode == WorkspaceMode.server,
          onPressed: () => _setMode(WorkspaceMode.server),
        ),
        const ToolbarDivider(),
        // 标题：连接名 + 用户@主机。点一下切换别的连接、新建、断开
        Builder(
          builder: (context) => InkWell(
            key: const ValueKey('connection-title'),
            borderRadius: BorderRadius.circular(6),
            // 菜单要从点击的位置弹出：按下时记位置，点完再开（只挂 onTapUp 时 InkWell 不响应点击）
            onTapDown: (details) => _titleTapPosition = details.globalPosition,
            onTap: () => _showConnectionMenu(_titleTapPosition),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_ws.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: mac.text)),
                      Text(_ws.subtitle, style: TextStyle(fontSize: 11, color: mac.secondaryText)),
                    ],
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_more, size: 14, color: mac.secondaryText),
                ],
              ),
            ),
          ),
        ),
        const Spacer(),
        ToolbarButton(
          icon: Icons.settings_outlined,
          tooltip: '偏好设置（${commandLabel(',')}）',
          onPressed: widget.onPreferences,
        ),
      ],
    );
  }

  Widget _buildTabBody(WorkspaceTab tab) {
    final table = tab.table;
    final modes = WorkspaceMode.values;
    return IndexedStack(
      index: modes.indexOf(tab.mode),
      children: [
        // 内容：只有筛选条和网格，SQL 编辑器藏起来
        if (tab.visited.contains(WorkspaceMode.content))
          table == null
              ? const _Hint(text: '在左侧选一张表')
              : QueryTab(
                  key: tab.contentKey,
                  runner: tab.contentRunner,
                  library: _library,
                  tokenize: (sql) => tokenizeSql(sql: sql),
                  onRan: (_) {},
                  onConnected: () {},
                  showEditor: false,
                  editorFontSize: widget.editorFontSize,
                )
        else
          const SizedBox.shrink(),
        if (tab.visited.contains(WorkspaceMode.structure))
          table == null
              ? const _Hint(text: '在左侧选一张表看结构')
              : StructurePanel(
                  source: _ws.schema,
                  database: tab.database,
                  table: table,
                  // 改表不增删表，侧栏清单不用刷；列变了，补全目录要重读
                  onAltered: () => _ensureCatalog(tab, force: true),
                )
        else
          const SizedBox.shrink(),
        if (tab.visited.contains(WorkspaceMode.query))
          QueryTab(
            key: tab.queryKey,
            runner: tab.queryRunner,
            library: _library,
            tokenize: (sql) => tokenizeSql(sql: sql),
            onRan: (sql) => _retitle(tab, sql),
            complete: (sql, cursor) => _complete(tab, sql, cursor),
            // ponytail: 每次查询成功都整库重读一遍目录（一条 information_schema 查询），
            // 这样建表、改表之后补全立刻跟上；几万列的大库再改成按需或增量
            onConnected: () => _ensureCatalog(tab, force: true),
            editorFontSize: widget.editorFontSize,
          )
        else
          const SizedBox.shrink(),
        if (tab.visited.contains(WorkspaceMode.server))
          _ServerPage(workspace: _ws)
        else
          const SizedBox.shrink(),
      ],
    );
  }
}

/// 服务器模式：服务器状态和用户与权限两页
class _ServerPage extends StatefulWidget {
  final Workspace workspace;

  const _ServerPage({required this.workspace});

  @override
  State<_ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<_ServerPage> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final ws = widget.workspace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: mac.window, border: Border(bottom: BorderSide(color: mac.separator))),
          alignment: Alignment.center,
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('服务器状态')),
              ButtonSegment(value: 1, label: Text('用户与权限')),
            ],
            selected: {_page},
            onSelectionChanged: (selected) => setState(() => _page = selected.first),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _page,
            children: [
              ServerStatusPanel(source: ws.server, serverLabel: '${ws.config.host}:${ws.config.port}'),
              UserAdminPanel(source: ws.users),
            ],
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;

  const _Hint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(child: Text(text, style: TextStyle(fontSize: 13, color: MacColors.of(context).tertiaryText)));
  }
}

class _WorkspaceError extends StatelessWidget {
  final String message;
  final VoidCallback onClose;

  const _WorkspaceError({required this.message, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer,
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          Expanded(child: SelectableText(message, style: TextStyle(fontSize: 12, color: scheme.onErrorContainer))),
          IconButton(tooltip: '关闭', onPressed: onClose, icon: Icon(Icons.close, size: 14, color: scheme.onErrorContainer)),
        ],
      ),
    );
  }
}

bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

/// macOS 用 ⌘，其他平台用 Ctrl
SingleActivator commandKey(LogicalKeyboardKey key) {
  return SingleActivator(key, meta: _isMac, control: !_isMac);
}

/// 提示里显示的快捷键写法
String commandLabel(String key) => _isMac ? '⌘$key' : 'Ctrl+$key';
