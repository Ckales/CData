import 'package:cdata_flutter/operation_log_dialog.dart';
import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:cdata_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

OperationLogEntry logEntry({
  required String sql,
  required bool succeeded,
  String message = '',
  int elapsedMs = 12,
}) {
  return OperationLogEntry(
    sessionId: BigInt.one,
    operation: 'query',
    detail: sql,
    succeeded: succeeded,
    message: message,
    executedAt: DateTime(2026, 10, 28, 12, 34, 56).millisecondsSinceEpoch,
    elapsedMs: BigInt.from(elapsedMs),
  );
}

Future<void> openLogs(
  WidgetTester tester, {
  required Future<List<OperationLogEntry>> Function() load,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOperationLogDialog(context, load: load),
            child: const Text('打开日志'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开日志'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('显示成功与失败日志、SQL、耗时和说明', (tester) async {
    await openLogs(
      tester,
      load: () async => [
        logEntry(sql: 'SELECT * FROM users', succeeded: true, elapsedMs: 8),
        logEntry(
          sql: 'DROP TABLE absent',
          succeeded: false,
          message: 'table missing',
          elapsedMs: 24,
        ),
      ],
    );

    expect(find.text('SQL 操作日志'), findsOneWidget);
    expect(find.text('SELECT * FROM users'), findsOneWidget);
    expect(find.text('DROP TABLE absent'), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('耗时 8 ms'), findsOneWidget);
    expect(find.text('table missing'), findsOneWidget);
    expect(find.textContaining('按偏好设置中的保留条数'), findsOneWidget);
  });

  testWidgets('按 SQL 或消息搜索，并可筛选失败记录', (tester) async {
    await openLogs(
      tester,
      load: () async => [
        logEntry(sql: 'SELECT * FROM users', succeeded: true),
        logEntry(
          sql: 'UPDATE users SET name = "x"',
          succeeded: false,
          message: 'permission denied',
        ),
      ],
    );

    await tester.enterText(
      find.byKey(const ValueKey('operation-log-search')),
      'permission',
    );
    await tester.pumpAndSettle();
    expect(find.text('UPDATE users SET name = "x"'), findsOneWidget);
    expect(find.text('SELECT * FROM users'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('operation-log-status-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅成功').last);
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的日志'), findsOneWidget);
  });

  testWidgets('加载失败显示错误并可重试', (tester) async {
    var attempts = 0;
    await openLogs(
      tester,
      load: () async {
        attempts++;
        if (attempts == 1) throw StateError('日志文件不可读');
        return [logEntry(sql: 'SELECT 1', succeeded: true)];
      },
    );

    expect(find.textContaining('日志文件不可读'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('SELECT 1'), findsOneWidget);
  });

  testWidgets('无日志时显示空状态', (tester) async {
    await openLogs(tester, load: () async => []);
    expect(find.text('暂无 SQL 操作日志'), findsOneWidget);
  });
}
