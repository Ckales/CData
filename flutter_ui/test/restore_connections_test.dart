import 'package:cdata_flutter/connection_screen.dart';

import 'dart:async';

import 'package:cdata_flutter/mac_widgets.dart';
import 'package:cdata_flutter/query_page.dart';
import 'package:cdata_flutter/workspace.dart';
import 'package:cdata_flutter/src/rust/api/connections.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/options.dart';
import 'package:cdata_flutter/src/rust/api/preferences.dart' as prefs;
import 'package:cdata_flutter/src/rust/api/schema.dart';
import 'package:cdata_flutter/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _RestoreApi api;
  setUp(() {
    api = _RestoreApi();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);
  testWidgets('连接完成前展示全部标签并选中上次页面，后台完成不抢焦点', (tester) async {
    api.gates = [Completer<BigInt>(), Completer<BigInt>()];
    await tester.pumpWidget(
      MaterialApp(
        home: QueryPage(
          preferences: prefs.Preferences(
            theme: prefs.ThemeMode.system,
            editorFontSize: 12,
            maxRows: BigInt.from(100),
            restoreConnections: true,
            transcriptHistoryLimit: 100,
            queryHistoryLimit: 100,
            saveQueryHistory: false,
            operationLogLimit: 100,
          ),
          onPreferencesChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final strip = tester.widget<MacTabStrip>(find.byType(MacTabStrip));
    expect(strip.tabs.map((tab) => tab.title), [
      'sportkeep',
      'unifly',
      'sportkeep',
    ]);
    expect(strip.active, 1);
    expect(api.started, 2);
    final loadingStripRect = tester.getRect(find.byType(MacTabStrip));
    expect(loadingStripRect.left, 230);
    expect(
      loadingStripRect.width,
      tester.view.physicalSize.width / tester.view.devicePixelRatio - 230,
    );
    expect(
      tester.getTopLeft(find.byKey(strip.tabs.first.key)).dx,
      loadingStripRect.left,
    );
    api.gates![1].complete(BigInt.from(2));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<MacTabStrip>(find.byType(MacTabStrip)).active, 1);
    api.gates![0].complete(BigInt.one);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(MacTabStrip)), loadingStripRect);
    expect(tester.widget<MacTabStrip>(find.byType(MacTabStrip)).active, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  Future<void> launchPending(WidgetTester tester) async {
    api.gates = [Completer<BigInt>(), Completer<BigInt>()];
    await tester.pumpWidget(
      MaterialApp(
        home: QueryPage(
          preferences: prefs.Preferences(
            theme: prefs.ThemeMode.system,
            editorFontSize: 12,
            maxRows: BigInt.from(100),
            restoreConnections: true,
            transcriptHistoryLimit: 100,
            queryHistoryLimit: 100,
            saveQueryHistory: false,
            operationLogLimit: 100,
          ),
          onPreferencesChanged: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('宽窗口恢复中和失败时标签栏均铺满内容区且左对齐', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await launchPending(tester);
    final loadingRect = tester.getRect(find.byType(MacTabStrip));
    expect(loadingRect.left, 230);
    expect(loadingRect.width, 1170);
    final strip = tester.widget<MacTabStrip>(find.byType(MacTabStrip));
    expect(tester.getTopLeft(find.byKey(strip.tabs.first.key)).dx, 230);
    api.gates![0].completeError(StateError('active unavailable'));
    api.gates![1].complete(BigInt.two);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(MacTabStrip)), loadingRect);
    expect(find.text('重新连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('后台失败静默，切到失败标签可见原因并重连', (tester) async {
    await launchPending(tester);
    api.gates![0].complete(BigInt.one);
    api.gates![1].completeError(StateError('background unavailable'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    final strip = tester.widget<MacTabStrip>(find.byType(MacTabStrip));
    strip.onSelect(2);
    await tester.pumpAndSettle();
    expect(find.textContaining('background unavailable'), findsOneWidget);
    api.gates = null;
    await tester.tap(find.text('重新连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('background unavailable'), findsNothing);
    expect(tester.widget<MacTabStrip>(find.byType(MacTabStrip)).active, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('当前连接失败显示正常错误且保留标签', (tester) async {
    await launchPending(tester);
    api.gates![0].completeError(StateError('active unavailable'));
    api.gates![1].complete(BigInt.two);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    expect(tester.widget<MacTabStrip>(find.byType(MacTabStrip)).active, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('恢复中切换并关闭连接，迟到的会话被关闭且不会恢复标签', (tester) async {
    await launchPending(tester);
    tester.widget<MacTabStrip>(find.byType(MacTabStrip)).onSelect(2);
    await tester.pump();
    final views = tester
        .widgetList<WorkspaceView>(
          find.byType(WorkspaceView, skipOffstage: false),
        )
        .toList();
    views.first.onDisconnect();
    await tester.pump();
    api.gates![0].complete(BigInt.one);
    api.gates![1].complete(BigInt.two);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MacTabStrip>(find.byType(MacTabStrip)).tabs,
      hasLength(1),
    );
    expect(api.closed, contains(BigInt.one));
    expect(api.opened, hasLength(1));
    expect(api.opened.single.active, isTrue);
    expect(api.opened.single.database, 'sportkeep');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('读取恢复列表期间手动连接，合并后保存全部连接并保留用户选择', (tester) async {
    api.metadataGate = Completer<void>();
    await launchPending(tester);
    api.gates = null;
    final screen = tester.widget<ConnectionScreen>(
      find.byType(ConnectionScreen),
    );
    final config = ConnectionConfig(
      host: '',
      port: 3306,
      user: '',
      password: '',
      database: 'manual',
      options: api.crateApiOptionsDefaultConnectionOptions(),
      sshSecrets: const [],
      savedId: 'test',
    );
    expect(await screen.onConnect(config, '手动连接', const []), isNull);
    await tester.pump();
    api.metadataGate!.complete();
    await tester.pumpAndSettle();
    expect(api.opened, hasLength(3));
    expect(api.opened.singleWhere((state) => state.active).database, 'manual');
    expect(tester.widget<MacTabStrip>(find.byType(MacTabStrip)).active, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  test('标签在视图初始化前也可以安全关闭', () async {
    final tab = WorkspaceTab(id: 1, mode: WorkspaceMode.content, database: '');
    await tab.close();
  });

  testWidgets('同一收藏的多个工作区和数据库标签经过保存重启均能恢复', (tester) async {
    Future<void> launch() async {
      await tester.pumpWidget(
        MaterialApp(
          home: QueryPage(
            preferences: prefs.Preferences(
              theme: prefs.ThemeMode.system,
              editorFontSize: 12,
              maxRows: BigInt.from(100),
              restoreConnections: true,
              transcriptHistoryLimit: 100,
              queryHistoryLimit: 100,
              saveQueryHistory: false,
              operationLogLimit: 100,
            ),
            onPreferencesChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    List<WorkspaceView> views() => tester
        .widgetList<WorkspaceView>(
          find.byType(WorkspaceView, skipOffstage: false),
        )
        .toList();
    await launch();
    expect(views(), hasLength(2));
    final first = views()[0].workspace;
    expect(first.tabs.map((tab) => tab.database), ['sportkeep', 'unifly']);
    expect(first.active, 1);
    expect(views()[1].workspace.tabs.single.database, 'sportkeep');
    expect(
      tester.widget<WorkspaceView>(find.byType(WorkspaceView)).workspace,
      same(first),
    );
    views()[0].onSwitch(views()[1].workspace, 0);
    await tester.pumpAndSettle();
    expect(api.opened, hasLength(2));
    expect(api.opened[0].tabs.map((tab) => tab.database), [
      'sportkeep',
      'unifly',
    ]);
    expect(api.opened[0].activeTab, 1);
    expect(api.opened[0].active, isFalse);
    expect(api.opened[1].active, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await launch();
    expect(views(), hasLength(2));
    expect(views()[0].workspace.tabs.map((tab) => tab.database), [
      'sportkeep',
      'unifly',
    ]);
    expect(
      tester.widget<WorkspaceView>(find.byType(WorkspaceView)).workspace,
      same(views()[1].workspace),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}

class _RestoreApi implements RustLibApi {
  List<OpenConnectionState> opened = const [
    OpenConnectionState(
      id: 'test',
      database: 'unifly',
      active: true,
      tabs: [
        OpenTabState(database: 'sportkeep'),
        OpenTabState(database: 'unifly'),
      ],
      activeTab: 1,
    ),
    OpenConnectionState(
      id: 'test',
      database: 'sportkeep',
      active: false,
      tabs: [],
      activeTab: 0,
    ),
  ];
  Completer<void>? metadataGate;
  int nextSession = 1;
  List<Completer<BigInt>>? gates;
  int started = 0;
  final List<BigInt> closed = [];
  @override
  ConnectionOptions crateApiOptionsDefaultConnectionOptions() =>
      const ConnectionOptions(
        ssl: SslOptions(mode: SslMode.disabled),
        timeouts: TimeoutOptions(connectSecs: 10),
        ssh: SshOptions(hops: []),
      );
  @override
  Future<List<OpenConnectionState>>
  crateApiConnectionsOpenConnections() async => opened;
  @override
  Future<void> crateApiConnectionsSaveOpenConnections({
    required List<OpenConnectionState> connections,
  }) async {
    opened = connections;
  }

  @override
  Future<List<SavedConnection>> crateApiConnectionsListConnections() async {
    await metadataGate?.future;
    return const [
      SavedConnection(
        id: 'test',
        name: '测试线',
        host: '',
        port: 3306,
        user: '',
        databases: [],
        options: ConnectionOptions(
          ssl: SslOptions(mode: SslMode.disabled),
          timeouts: TimeoutOptions(connectSecs: 10),
          ssh: SshOptions(hops: []),
        ),
      ),
    ];
  }

  @override
  Future<BigInt> crateApiDbOpenSession({
    required ConnectionConfig config,
  }) async {
    final index = started++;
    return gates == null
        ? BigInt.from(nextSession++)
        : await gates![index].future;
  }

  @override
  Future<void> crateApiDbCloseSession({required BigInt sessionId}) async {
    closed.add(sessionId);
  }

  @override
  Future<List<String>> crateApiSchemaListDatabases({
    required BigInt sessionId,
  }) async => ['sportkeep', 'unifly'];
  @override
  Future<List<TableInfo>> crateApiSchemaListTables({
    required BigInt sessionId,
    required String database,
  }) async => [];
  @override
  Future<BigInt> crateApiEditorLoadCatalog({
    required BigInt sessionId,
    required String database,
  }) async => BigInt.zero;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
