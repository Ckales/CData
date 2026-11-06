import 'package:cdata_flutter/mac_widgets.dart';
import 'package:cdata_flutter/table_sidebar.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/options.dart';
import 'package:cdata_flutter/src/rust/api/schema.dart';
import 'package:cdata_flutter/src/rust/api/editor.dart';
import 'package:cdata_flutter/src/rust/frb_generated.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:cdata_flutter/workspace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => RustLib.initMock(api: _SidebarApi()));
  tearDown(RustLib.dispose);

  testWidgets('重复点击当前表不再加载，换表和从查询返回仍会加载', (tester) async {
    RustLib.dispose();
    final api = _SidebarApi();
    RustLib.initMock(api: api);
    final workspace = _workspace(1);
    workspace.activeTab.database = 'shop';
    var selectionChanges = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: WorkspaceView(
          workspace: workspace,
          all: [workspace],
          onSwitch: (_, _) {},
          onCloseTab: (_, _) {},
          onNewConnection: () {},
          onDisconnect: () {},
          onSelectionChanged: () => selectionChanges++,
          onPreferences: () {},
          maxRows: () => BigInt.from(100),
          editorFontSize: 12,
          confirmHostKey: (_) async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder table(String name) => find.descendant(
      of: find.byType(TableSidebar),
      matching: find.text(name),
    );
    await tester.tap(table('users'));
    // 同一帧内再次点击，也不应排入第二次加载。
    await tester.tap(table('users'));
    await tester.pumpAndSettle();
    expect(api.browsedTables, ['users']);
    expect(api.executedSql, ['SELECT * FROM users']);
    expect(selectionChanges, 1);

    await tester.tap(table('users'));
    await tester.pumpAndSettle();
    expect(api.browsedTables, ['users']);
    expect(selectionChanges, 1);

    await tester.tap(table('orders'));
    await tester.pumpAndSettle();
    expect(api.browsedTables, ['users', 'orders']);
    expect(api.executedSql.length, 2);

    workspace.activeTab.mode = WorkspaceMode.query;
    await tester.tap(table('orders'));
    await tester.pumpAndSettle();
    expect(workspace.activeTab.mode, WorkspaceMode.content);
    expect(api.browsedTables, ['users', 'orders', 'orders']);
    expect(api.executedSql.length, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('跨连接拖动只改变显示顺序，切换、关闭和新增标签仍对应原连接', (tester) async {
    final first = _workspace(1);
    final second = _workspace(2);
    final keys = [
      GlobalKey<WorkspaceViewState>(),
      GlobalKey<WorkspaceViewState>(),
    ];
    final all = [first, second];
    var active = 0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return IndexedStack(
                index: active,
                children: [
                  for (var i = 0; i < all.length; i++)
                    WorkspaceView(
                      key: keys[i],
                      workspace: all[i],
                      all: all,
                      onSwitch: (workspace, tab) {
                        keys[all.indexOf(workspace)].currentState!.selectTab(
                          tab,
                        );
                        setState(() => active = all.indexOf(workspace));
                      },
                      onCloseTab: (workspace, tab) {
                        keys[all.indexOf(workspace)].currentState!.closeTab(
                          tab,
                        );
                        setState(() {});
                      },
                      onNewConnection: () {},
                      onDisconnect: () {},
                      onSelectionChanged: () {},
                      onPreferences: () {},
                      maxRows: () => BigInt.from(100),
                      editorFontSize: 12,
                      confirmHostKey: (_) async => false,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final sidebar = find.byType(TableSidebar).first;
    final handle = find.byKey(const ValueKey('sidebar-resize-handle')).first;
    expect(tester.getSize(sidebar).width, 225);
    await tester.drag(handle, const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 325);
    await tester.drag(handle, const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 435);
    await tester.drag(handle, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 180);
    expect(tester.takeException(), isNull);
    keys[0].currentState!.duplicateTab();
    rebuild(() {});
    await tester.pumpAndSettle();

    final a = first.tabs[0];
    final b = second.tabs.single;
    final c = first.tabs[1];
    List<Key> order() => tester
        .widget<MacTabStrip>(find.byType(MacTabStrip))
        .tabs
        .map((tab) => tab.key)
        .toList();
    Key key(WorkspaceTab tab) => ValueKey('tab-${tab.id}');
    expect(order(), [key(a), key(b), key(c)]);
    final start = tester.getTopLeft(find.byKey(key(c))) + const Offset(112, 16);
    final end = tester.getCenter(find.byKey(key(b)));
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(order(), [key(a), key(c), key(b)]);
    expect(first.activeTab, same(c));
    expect(first.tabs, [a, c]);
    expect(second.tabs, [b]);

    await _dragTab(tester, key(a), key(b));
    expect(order(), [key(c), key(b), key(a)]);
    expect(first.activeTab, same(c));

    // 后台连接的标签也能直接拖动，不用先切换连接。
    await _dragTab(tester, key(b), key(c));
    expect(order(), [key(b), key(c), key(a)]);
    expect(active, 0);
    expect(first.activeTab, same(c));

    await tester.tap(find.byKey(key(b)));
    await tester.pumpAndSettle();
    expect(active, 1);
    expect(order(), [key(b), key(c), key(a)]);

    await tester.tap(find.byKey(key(c)));
    await tester.pumpAndSettle();
    expect(active, 0);
    expect(first.activeTab, same(c));

    final close = find.descendant(
      of: find.byKey(key(c)),
      matching: find.byIcon(Icons.close),
    );
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(order(), [key(b), key(a)]);

    keys[0].currentState!.duplicateTab();
    await tester.pumpAndSettle();
    final added = first.tabs.last;
    expect(order(), [key(b), key(a), key(added)]);
    expect(first.activeTab, same(added));
  });
}

Future<void> _dragTab(WidgetTester tester, Key from, Key to) async {
  final start = tester.getTopLeft(find.byKey(from)) + const Offset(112, 16);
  final end = tester.getCenter(find.byKey(to));
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(Offset(end.dx > start.dx ? 20 : -20, 0));
  await tester.pump();
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Workspace _workspace(int id) => Workspace(
  id: id,
  name: '连接 $id',
  schemaId: BigInt.from(id),
  config: const ConnectionConfig(
    host: 'example.invalid',
    port: 3306,
    user: '',
    password: '',
    options: ConnectionOptions(
      ssl: SslOptions(mode: SslMode.disabled),
      timeouts: TimeoutOptions(connectSecs: 10),
      ssh: SshOptions(hops: []),
    ),
    sshSecrets: [],
  ),
);

class _SidebarApi implements RustLibApi {
  final browsedTables = <String>[];
  final executedSql = <String>[];

  @override
  Future<List<TableInfo>> crateApiSchemaListTables({
    required BigInt sessionId,
    required String database,
  }) async => [
    for (final name in ['users', 'orders'])
      TableInfo(name: name, estimatedRows: BigInt.zero, isView: false),
  ];

  @override
  Future<BigInt> crateApiEditorLoadCatalog({
    required BigInt sessionId,
    required String database,
  }) async => BigInt.zero;

  @override
  Future<String> crateApiSchemaBrowseSql({required String table}) async {
    browsedTables.add(table);
    return 'SELECT * FROM $table';
  }

  @override
  Future<BigInt> crateApiDbOpenSession({
    required ConnectionConfig config,
  }) async => BigInt.one;

  @override
  List<String> crateApiEditorSplitStatements({required String sql}) => [sql];

  @override
  List<SqlToken> crateApiEditorTokenizeSql({required String sql}) => [];

  @override
  Future<void> crateApiEditorAddHistory({required String sql}) async {}

  @override
  Future<void> crateApiEditorDropChildResults({
    required BigInt sessionId,
  }) async {}

  @override
  Future<QuerySummary> crateApiDbExecuteFilteredView({
    required BigInt sessionId,
    required String sql,
    required FilterGroup filter,
    String? sortColumn,
    required bool sortAscending,
    required BigInt maxRows,
  }) async {
    executedSql.add(sql);
    return QuerySummary(
      columns: [],
      totalRows: BigInt.zero,
      truncated: false,
      editability: const Editability.readOnly('test'),
    );
  }

  @override
  Future<List<String>> crateApiSchemaListDatabases({
    required BigInt sessionId,
  }) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
