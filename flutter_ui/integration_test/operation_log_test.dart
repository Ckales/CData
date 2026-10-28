// 不连数据库：验证日志跨 FFI 读取和 macOS 日志窗口。
import 'package:cdata_flutter/operation_log_dialog.dart';
import 'package:cdata_flutter/src/rust/api/operation_log.dart';
import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rust_init.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureRustInit);

  testWidgets('日志跨 FFI 读取并在 macOS 显示 SQL 及状态', (tester) async {
    final stored = await listOperationLogs();
    expect(stored.length, lessThanOrEqualTo(10000));
    // 固定样例只用于界面验收，不写入用户日志。
    final entries = [
      OperationLogEntry(
        sessionId: BigInt.one,
        operation: 'update',
        detail: "UPDATE `shop`.`users` SET `scope` = '2' WHERE `id` = 1 LIMIT 1",
        succeeded: true,
        message: '完成',
        executedAt: DateTime.now().millisecondsSinceEpoch,
        elapsedMs: BigInt.from(12),
      ),
      OperationLogEntry(
        sessionId: BigInt.one,
        operation: 'query',
        detail: 'SELECT * FROM `missing_table`',
        succeeded: false,
        message: 'MySQL error 1146 (SQLSTATE 42S02)',
        executedAt: DateTime.now().millisecondsSinceEpoch,
        elapsedMs: BigInt.from(3),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showOperationLogDialog(context, load: () async => entries),
              child: const Text('日志'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();
    expect(find.text('SQL 操作日志'), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    expect(find.text(entries.first.detail), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
