// 真实 FFI 往返；启动测试时必须把状态路径指向临时目录，不连接数据库。
import 'dart:io';

import 'package:cdata_flutter/src/rust/api/connections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rust_init.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureRustInit);

  testWidgets('多个数据库标签和同收藏的工作区跨 FFI 保存恢复', (tester) async {
    final directory = Platform.environment['CDATA_RESTORE_TEST_DIR'];
    expect(directory, isNotNull, reason: '必须使用专用临时目录');
    expect(
      Platform.environment['CDATA_OPEN_CONNECTIONS_PATH'],
      '$directory/open_connections.json',
    );
    expect(
      Platform.environment['CDATA_OPEN_SELECTIONS_PATH'],
      '$directory/open_selections.json',
    );
    const states = [
      OpenConnectionState(
        id: 'test',
        database: 'unifly',
        table: 'models',
        active: true,
        tabs: [
          OpenTabState(database: 'sportkeep', table: 'events'),
          OpenTabState(database: 'unifly', table: 'models'),
        ],
        activeTab: 1,
      ),
      OpenConnectionState(
        id: 'test',
        database: 'sportkeep',
        active: false,
        tabs: [OpenTabState(database: 'sportkeep')],
        activeTab: 0,
      ),
    ];
    await tester.runAsync(() async {
      await saveOpenConnections(connections: states);
      final restored = await openConnections();
      expect(restored, hasLength(2));
      expect(restored[0].tabs, states[0].tabs);
      expect(restored[0].activeTab, 1);
      expect(restored[0].active, isTrue);
      expect(restored[1].database, 'sportkeep');
      expect(restored[1].active, isFalse);
    });
  });
}
