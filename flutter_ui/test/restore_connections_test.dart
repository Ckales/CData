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
  int nextSession = 1;
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
  Future<List<SavedConnection>> crateApiConnectionsListConnections() async =>
      const [
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
  @override
  Future<BigInt> crateApiDbOpenSession({
    required ConnectionConfig config,
  }) async => BigInt.from(nextSession++);
  @override
  Future<void> crateApiDbCloseSession({required BigInt sessionId}) async {}
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
