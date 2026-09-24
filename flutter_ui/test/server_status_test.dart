// 服务器状态页的 widget 测试。进程怎么读、KILL 怎么拦、SET 语句怎么生成、差值怎么算
// 由 cdata-core 的测试保证，这里管界面：二次确认有没有、说没说清楚、传给数据源的对不对。

import 'package:cdata_flutter/server_source.dart';
import 'package:cdata_flutter/server_status.dart';
import 'package:cdata_flutter/src/rust/api/server.dart';
import 'package:cdata_flutter/src/rust/api/value.dart' show DisplayCell;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DisplayCell text(String value) => DisplayCell(text: value, placeholder: false);

const nullCell = DisplayCell(text: 'NULL', placeholder: true);

ProcessInfo process(int id, {String user = 'app', String info = 'SELECT SLEEP(30)', bool own = false}) {
  return ProcessInfo(
    id: BigInt.from(id),
    user: text(user),
    host: text('10.0.0.8:5123'),
    db: text('shop'),
    command: text(info.isEmpty ? 'Sleep' : 'Query'),
    time: text('12'),
    state: text(info.isEmpty ? '' : 'User sleep'),
    info: info.isEmpty ? nullCell : text(info),
    isOwn: own,
  );
}

class FakeServerSource implements ServerSource {
  ProcessList processList;
  Object? killError;
  final kills = <(ProcessInfo, KillMode)>[];
  int processCalls = 0;

  Map<VariableScope, List<Variable>> variableLists;
  final variableCalls = <VariableScope>[];
  final previews = <(String, String)>[];
  final applies = <(String, String, String)>[];

  final statusPrevious = <StatusSnapshot?>[];
  List<StatusSnapshot> statuses;

  SlowLogConfig slowConfig;
  List<SlowLogEntry> slowEntries;
  final slowLimits = <int>[];

  FakeServerSource({
    required this.processList,
    this.variableLists = const {},
    this.statuses = const [],
    required this.slowConfig,
    this.slowEntries = const [],
  });

  @override
  Future<ProcessList> processes() async {
    processCalls++;
    return processList;
  }

  @override
  Future<void> kill(ProcessInfo target, KillMode mode) async {
    kills.add((target, mode));
    if (killError != null) throw killError!;
  }

  @override
  Future<VariableList> variables(VariableScope scope) async {
    variableCalls.add(scope);
    return VariableList(variables: variableLists[scope] ?? const [], truncated: false);
  }

  @override
  Future<StatusSnapshot> status(StatusSnapshot? previous) async {
    statusPrevious.add(previous);
    return statuses[statusPrevious.length - 1];
  }

  @override
  Future<SlowLogConfig> slowLogConfig() async => slowConfig;

  @override
  Future<List<SlowLogEntry>> slowLogEntries(int limit) async {
    slowLimits.add(limit);
    return slowEntries;
  }

  @override
  Future<SetVariablePlan> previewSetGlobal(String name, String value) async {
    previews.add((name, value));
    return SetVariablePlan(
      statement: 'SET GLOBAL $name = $value',
      currentValue: text('10.000000'),
      warnings: const ['重启后恢复成配置文件里的值'],
    );
  }

  @override
  Future<DisplayCell> applySetGlobal(String name, String value, String statement) async {
    applies.add((name, value, statement));
    return text('2.000000');
  }
}

SlowLogConfig slowConfig({String output = 'FILE', bool enabled = false, String? unavailable}) {
  return SlowLogConfig(
    slowQueryLog: text(enabled ? 'ON' : 'OFF'),
    logOutput: text(output),
    longQueryTime: text('10.000000'),
    slowQueryLogFile: text('/var/lib/mysql/db-slow.log'),
    enabled: enabled,
    tableUnavailable: unavailable,
  );
}

FakeServerSource sourceOf({ProcessList? processes, SlowLogConfig? slow}) {
  return FakeServerSource(
    processList: processes ??
        ProcessList(
          processes: [process(7, info: 'SHOW FULL PROCESSLIST', own: true), process(9), process(11, info: '')],
          truncated: false,
        ),
    variableLists: {
      VariableScope.global: [
        Variable(name: 'long_query_time', value: text('10.000000')),
        Variable(name: 'max_connections', value: text('151')),
        Variable(name: 'init_connect', value: text('')),
      ],
      VariableScope.session: [Variable(name: 'character_set_client', value: text('utf8mb4'))],
    },
    statuses: [
      StatusSnapshot(
        takenAtMs: BigInt.from(1000),
        counters: [
          StatusCounter(name: 'Questions', value: text('100')),
          StatusCounter(name: 'Threads_running', value: text('2')),
        ],
        truncated: false,
      ),
      StatusSnapshot(
        takenAtMs: BigInt.from(3000),
        counters: [
          StatusCounter(name: 'Questions', value: text('120'), delta: '+20', rate: '10.0/s'),
          StatusCounter(name: 'Threads_running', value: text('3'), delta: '+1'),
        ],
        truncated: false,
      ),
    ],
    slowConfig: slow ?? slowConfig(unavailable: 'log_output = FILE：慢日志写在服务器上的文件 /var/lib/mysql/db-slow.log 里'),
  );
}

Future<void> open(WidgetTester tester, FakeServerSource source) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => showServerStatus(context, source: source, serverLabel: '127.0.0.1:3306'),
        child: const Text('打开'),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

/// 输入框有焦点时光标一直闪，pumpAndSettle 等不到稳定，用有限次 pump
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('进程列表：自己的连接标出来、不给 KILL；权限不足的原因显示出来', (tester) async {
    final source = sourceOf(
      processes: ProcessList(
        processes: [process(7, info: 'SHOW FULL PROCESSLIST', own: true), process(9)],
        truncated: false,
        notice: '当前账号没有 PROCESS 权限，MySQL 只返回本账号自己的线程',
      ),
    );
    await open(tester, source);

    expect(find.text('服务器状态 · 127.0.0.1:3306'), findsOneWidget);
    expect(find.textContaining('没有 PROCESS 权限'), findsOneWidget);
    expect(find.byKey(const ValueKey('process-own-7')), findsOneWidget);
    expect(find.byKey(const ValueKey('process-own-9')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('process-7')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('process-kill-query')), findsNothing);
    expect(find.byKey(const ValueKey('process-kill-connection')), findsNothing);
    expect(find.textContaining('CData 自己正在用的连接'), findsWidgets);
  });

  testWidgets('KILL QUERY 要二次确认，确认框说清两种 KILL 的区别；取消就不执行', (tester) async {
    final source = sourceOf();
    await open(tester, source);

    await tester.tap(find.byKey(const ValueKey('process-9')));
    await tester.pumpAndSettle();
    // 完整语句显示在下面
    expect(find.descendant(of: find.byKey(const ValueKey('process-detail-sql')), matching: find.text('SELECT SLEEP(30)')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('process-kill-query')));
    await tester.pumpAndSettle();
    expect(find.text('终止线程 9 正在执行的语句？'), findsOneWidget);
    expect(find.textContaining('KILL QUERY：只停掉这条连接正在执行的那条语句'), findsOneWidget);
    expect(find.textContaining('KILL CONNECTION：断开整条连接'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('kill-cancel')));
    await tester.pumpAndSettle();
    expect(source.kills, isEmpty, reason: '取消了不能 KILL');

    await tester.tap(find.byKey(const ValueKey('process-kill-connection')));
    await tester.pumpAndSettle();
    expect(find.text('断开线程 9 的整条连接？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kill-confirm')));
    await tester.pumpAndSettle();

    final (target, mode) = source.kills.single;
    expect(target.id, BigInt.from(9));
    expect(target.info.text, 'SELECT SLEEP(30)', reason: '传回确认时看到的那一行，core 按它核对');
    expect(mode, KillMode.connection);
    expect(find.text('已对线程 9 执行 KILL CONNECTION'), findsOneWidget);
  });

  testWidgets('core 拒绝 KILL 时原因显示出来', (tester) async {
    final source = sourceOf()..killError = '线程 9 现在执行的语句和确认时不一样了，没有 KILL，请刷新后重新确认';
    await open(tester, source);

    await tester.tap(find.byKey(const ValueKey('process-9')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('process-kill-query')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kill-confirm')));
    await tester.pumpAndSettle();

    expect(source.kills.single.$2, KillMode.query);
    expect(find.textContaining('KILL 没有执行：线程 9 现在执行的语句和确认时不一样了'), findsOneWidget);
  });

  testWidgets('空闲线程的语句是 NULL 占位，不是空白', (tester) async {
    final source = sourceOf();
    await open(tester, source);

    final nulls = tester.widgetList<Text>(find.text('NULL')).toList();
    expect(nulls, isNotEmpty);
    expect(nulls.every((t) => t.style?.fontStyle == FontStyle.italic), isTrue);
  });

  testWidgets('自动刷新按选的间隔跑，关掉就停', (tester) async {
    final source = sourceOf();
    await open(tester, source);
    expect(source.processCalls, 1);

    await tester.tap(find.byKey(const ValueKey('processes-auto')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每 2 秒刷新').last);
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(source.processCalls, 2);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(source.processCalls, 3);

    await tester.tap(find.byKey(const ValueKey('processes-auto')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不自动刷新').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    expect(source.processCalls, 3);
  });

  testWidgets('变量：按名字搜索；改全局值先预览、说明影响，确认后执行', (tester) async {
    final source = sourceOf();
    await open(tester, source);
    await openTab(tester, '变量');

    expect(source.variableCalls, [VariableScope.global]);
    expect(find.text('max_connections'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('variables-search')), 'QUERY');
    await settle(tester);
    expect(find.text('max_connections'), findsNothing);
    expect(find.text('long_query_time'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('variable-edit-long_query_time')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('set-global-value')), '2');
    await tester.tap(find.byKey(const ValueKey('set-global-preview')));
    await settle(tester);

    expect(source.previews.single, ('long_query_time', '2'));
    expect(source.applies, isEmpty, reason: '预览不执行');
    expect(find.text('SET GLOBAL long_query_time = 2'), findsOneWidget);
    expect(find.textContaining('重启后恢复'), findsOneWidget);
    expect(find.text('我已了解影响，执行 SET GLOBAL'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('set-global-apply')));
    await settle(tester);
    expect(source.applies.single, ('long_query_time', '2', 'SET GLOBAL long_query_time = 2'));
    expect(find.text('2.000000'), findsOneWidget, reason: '显示服务器实际存下的值');

    await tester.tap(find.byKey(const ValueKey('set-global-done')));
    await settle(tester);
    expect(source.variableCalls, [VariableScope.global, VariableScope.global], reason: '改完重读');
  });

  testWidgets('取消改全局值不执行', (tester) async {
    final source = sourceOf();
    await open(tester, source);
    await openTab(tester, '变量');

    await tester.tap(find.byKey(const ValueKey('variable-edit-max_connections')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('set-global-preview')));
    await settle(tester);
    expect(source.previews.single, ('max_connections', '151'), reason: '默认填现在的值');
    await tester.tap(find.byKey(const ValueKey('set-global-cancel')));
    await settle(tester);
    expect(source.applies, isEmpty);
  });

  testWidgets('会话变量只读，并说明为什么', (tester) async {
    final source = sourceOf();
    await open(tester, source);
    await openTab(tester, '变量');

    await tester.tap(find.text('会话 SESSION'));
    await tester.pumpAndSettle();
    expect(source.variableCalls.last, VariableScope.session);
    expect(find.text('character_set_client'), findsOneWidget);
    expect(find.byKey(const ValueKey('variable-edit-character_set_client')), findsNothing);
    expect(find.textContaining('连接每次归还都会重置'), findsOneWidget);
  });

  testWidgets('状态：刷新时把上一次的快照交回去，显示 core 算的差值和每秒', (tester) async {
    final source = sourceOf();
    await open(tester, source);
    await openTab(tester, '状态');

    expect(source.statusPrevious.single, isNull);
    await tester.tap(find.byKey(const ValueKey('status-refresh')));
    await tester.pumpAndSettle();
    expect(source.statusPrevious.last?.takenAtMs, BigInt.from(1000));
    expect(find.text('+20'), findsOneWidget);
    expect(find.text('10.0/s'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('status-search')), 'threads');
    await settle(tester);
    expect(find.text('Questions'), findsNothing);
    expect(find.text('Threads_running'), findsOneWidget);
  });

  testWidgets('慢日志只写文件时如实说明，不去读表', (tester) async {
    final source = sourceOf();
    await open(tester, source);
    await openTab(tester, '慢日志');

    expect(find.textContaining('/var/lib/mysql/db-slow.log 里'), findsOneWidget);
    expect(source.slowLimits, isEmpty);
    expect(find.byKey(const ValueKey('slow-limit')), findsNothing);
  });

  testWidgets('慢日志写表时读最近几条；开关慢日志走 SET GLOBAL 的确认流程', (tester) async {
    final source = sourceOf(slow: slowConfig(output: 'FILE,TABLE'))
      ..slowEntries = [
        SlowLogEntry(
          startTime: text('2026-09-24 10:00:00.000000'),
          userHost: text('app[app] @ localhost []'),
          queryTime: text('00:00:12.000000'),
          lockTime: text('00:00:00.000000'),
          rowsSent: text('1'),
          rowsExamined: text('100000'),
          db: text('shop'),
          sqlText: const DisplayCell(text: '<无法解码 12 字节>', placeholder: true),
        ),
      ];
    await open(tester, source);
    await openTab(tester, '慢日志');

    expect(source.slowLimits, [20]);
    expect(find.textContaining('慢日志现在是关闭的'), findsOneWidget);
    expect(find.text('00:00:12.000000'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('slow-toggle')));
    await settle(tester);
    expect(source.previews.single, ('slow_query_log', 'ON'));
    expect(find.text('SET GLOBAL slow_query_log = ON'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('set-global-apply')));
    await settle(tester);
    expect(source.applies.single.$1, 'slow_query_log');
  });
}
