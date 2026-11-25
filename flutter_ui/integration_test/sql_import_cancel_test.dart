import 'dart:io';

import 'package:cdata_flutter/sql_import_dialog.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rust_init.dart';

const _host = String.fromEnvironment('HOST');
const _db = String.fromEnvironment('DB');

Future<void> _waitForText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  expect(finder, findsOneWidget);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureRustInit);

  testWidgets('执行中的 SQL 可以取消，随后关闭导入窗口', (tester) async {
    final fixture = await Directory.systemTemp.createTemp(
      'cdata-import-cancel',
    );
    addTearDown(() => fixture.delete(recursive: true));
    final file = await File('${fixture.path}/slow.sql')
        .writeAsString("SELECT ';'; SELECT SLEEP(60);");
    final session = await openSession(
      config: ConnectionConfig(
        host: _host,
        port: int.parse(const String.fromEnvironment('PORT')),
        user: const String.fromEnvironment('USER'),
        password: const String.fromEnvironment('PASSWORD'),
        database: _db,
        options: defaultConnectionOptions(),
        sshSecrets: const [],
      ),
    );
    addTearDown(() => closeSession(sessionId: session));

    bool? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                changed = await showSqlImportDialog(
                  context,
                  sessionId: session,
                  database: _db,
                  initialPath: file.path,
                );
              },
              child: const Text('打开导入'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('执行导入'));
    await _waitForText(tester, '已执行 1 / 2 条');
    await tester.tap(find.text('取消导入'));
    await _waitForText(tester, '导入已取消');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('导入 SQL'), findsNothing);
    expect(changed, isTrue);
  }, skip: _host.isEmpty);
}
