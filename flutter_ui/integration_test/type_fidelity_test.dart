// 类型保真的跨 FFI 回归测试。
//
// cdata-core 里已经测过映射规则，这里测的是另一件事：值穿过 FFI 到 Dart 之后有没有变形。
// u64 上界、DECIMAL 文本、零日期这三条是最容易在这一跳出问题的。
//
// 运行：见 integration_test/all_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:cdata_flutter/data_source.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/editor.dart' as editor;
import 'package:cdata_flutter/src/rust/api/options.dart';
import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rust_init.dart';

const _host = String.fromEnvironment('HOST');
const _port = String.fromEnvironment('PORT');
const _user = String.fromEnvironment('USER');
const _password = String.fromEnvironment('PASSWORD');
const _db = String.fromEnvironment('DB');

ConnectionConfig _config({ConnectionOptions? options}) => ConnectionConfig(
      host: _host,
      port: int.parse(_port),
      user: _user,
      password: _password,
      database: _db,
      options: options ?? defaultConnectionOptions(),
      sshSecrets: const [],
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureRustInit);

  test('unsigned BIGINT 上界穿过 FFI 不丢精度', () async {
    // Dart 的 int 是 64 位有符号，这个值只能靠 BigInt 承载
    final max = BigInt.parse('18446744073709551615');
    expect(await displayText(value: CellValue.uInt(max)), '18446744073709551615');
  });

  test('DECIMAL 保持精确文本', () async {
    expect(
      await displayText(value: const CellValue.text('1234567.89')),
      '1234567.89',
    );
  });

  test('零日期原样保留', () async {
    expect(
      await displayText(value: const CellValue.text('0000-00-00')),
      '0000-00-00',
    );
  });

  test('中文文本往返正确', () async {
    expect(
      await displayText(value: const CellValue.text('订单已完成')),
      '订单已完成',
    );
  });

  test('NULL 与不可读内容有明确占位，不冒充空值', () async {
    expect(await displayText(value: const CellValue.null_()), 'NULL');
    expect(
      await displayText(value: CellValue.bytes(Uint8List.fromList(List.filled(12, 0)))),
      '<二进制 12 字节>',
    );
    expect(
      await displayText(value: CellValue.invalidText(Uint8List.fromList([0xE9, 0x42]))),
      '<无法解码 2 字节>',
    );
  });

  test('剪贴板解析穿过 FFI 后 NULL 和文本 "NULL" 不混', () async {
    final rows = await parseClipboard(text: 'NULL\t"NULL"\t\r\n');
    expect(rows, [
      [const CellValue.null_(), const CellValue.text('NULL'), const CellValue.text('')],
    ]);
  });

  test('新增行的 null（默认）和 CellValue（写值）穿过 FFI 不混淆，删除按下标生效', () async {
    if (_host.isEmpty) {
      markTestSkipped('未通过 --dart-define 提供连接信息');
      return;
    }

    final sessionId = await openSession(
      config: _config(),
    );
    final summary = await execute(
      sessionId: sessionId,
      sql: 'SELECT id, name, amount, note FROM edit_target ORDER BY id',
      maxRows: BigInt.from(100),
    );
    final source = RustGridSource(sessionId: sessionId, summary: summary);
    final before = summary.totalRows.toInt();

    // id 交给自增，name 写空字符串 —— 空串和「不写」必须是两回事
    final total = await source.insertRow([null, const CellValue.text(''), null, null]);
    expect(total, before + 1);

    final row = await source.row(before);
    expect(row[0], isA<CellValue_Int>(), reason: '自增主键要回填');
    expect(row[1], const CellValue.text(''), reason: '空字符串不能变成 DEFAULT 的 NULL');
    expect(row[3], const CellValue.null_());

    expect(await source.deleteRows([before]), before);
    await closeSession(sessionId: sessionId);
  });

  test('筛选条件和排序穿过 FFI 生成正确的查询', () async {
    if (_host.isEmpty) {
      markTestSkipped('未通过 --dart-define 提供连接信息');
      return;
    }

    final sessionId = await openSession(
      config: _config(),
    );
    final summary = await executeView(
      sessionId: sessionId,
      sql: 'SELECT * FROM big_rows',
      conditions: const [
        FilterCondition(column: 'id', op: FilterOp.ltEq, value: '3'),
        FilterCondition(column: 'name', op: FilterOp.startsWith, value: '用户'),
      ],
      matchAll: true,
      sortColumn: 'id',
      sortAscending: false,
      maxRows: BigInt.from(100),
    );
    expect(summary.totalRows, BigInt.from(3));

    final rows = await fetchWindowText(sessionId: sessionId, offset: BigInt.zero, limit: BigInt.one);
    expect(rows.first.first.text, '3', reason: '降序后第一行是 3');
    await closeSession(sessionId: sessionId);
  });

  test('导出穿过 FFI 写出的文件和选项一致', () async {
    if (_host.isEmpty) {
      markTestSkipped('未通过 --dart-define 提供连接信息');
      return;
    }

    final sessionId = await openSession(
      config: _config(),
    );
    final summary = await executeView(
      sessionId: sessionId,
      sql: 'SELECT id, name FROM big_rows',
      conditions: const [FilterCondition(column: 'id', op: FilterOp.ltEq, value: '2')],
      matchAll: true,
      sortColumn: 'id',
      sortAscending: true,
      maxRows: BigInt.from(100),
    );
    final source = RustGridSource(sessionId: sessionId, summary: summary);

    final dir = await Directory.systemTemp.createTemp('cdata-export');
    final path = '${dir.path}/rows.tsv';
    final result = await source.exportRows(
      path,
      0,
      null,
      [1, 0],
      const ExportOptions(
        format: ExportFormat.csv,
        encoding: ExportEncoding.utf8,
        delimiter: '\t',
        header: true,
        nullText: 'NULL',
        tableName: '',
      ),
    );
    expect(result.rowsWritten, BigInt.from(2));
    expect(File(path).readAsStringSync(), 'name\tid\r\n用户1\t1\r\n用户2\t2\r\n');

    await dir.delete(recursive: true);
    await closeSession(sessionId: sessionId);
  });

  test('连接选项穿过 FFI：默认值来自 core，矛盾的选项在 openSession 就被拒绝', () async {
    final defaults = defaultConnectionOptions();
    expect(defaults.ssl.mode, SslMode.disabled);
    expect(defaults.timeouts.connectSecs, 10);
    expect(defaults.timeouts.querySecs, isNull);
    expect(defaults.ssh.hops, isEmpty);

    if (_host.isEmpty) {
      markTestSkipped('未通过 --dart-define 提供连接信息');
      return;
    }

    // Required 不校验证书，填了 CA 说不通：拒绝，而且是带人话的 OpenSessionError
    final contradictory = ConnectionOptions(
      ssl: SslOptions(mode: SslMode.required_, caPath: Platform.resolvedExecutable),
      timeouts: defaults.timeouts,
      ssh: defaults.ssh,
    );
    await expectLater(
      openSession(config: _config(options: contradictory)),
      throwsA(isA<OpenSessionError>()
          .having((e) => e.hostKey, 'hostKey', isNull)
          .having((e) => e.toString(), 'message', contains('VerifyIdentity'))),
    );

    // 查询超时穿过 FFI 后在 core 里生效
    final limited = ConnectionOptions(
      ssl: defaults.ssl,
      timeouts: const TimeoutOptions(connectSecs: 10, querySecs: 1),
      ssh: defaults.ssh,
    );
    final sessionId = await openSession(config: _config(options: limited));
    await expectLater(
      execute(sessionId: sessionId, sql: 'SELECT SLEEP(3)', maxRows: BigInt.one),
      throwsA(contains('已让服务器停止')),
    );
    await closeSession(sessionId: sessionId);
  });

  test('多语句脚本和执行计划穿过 FFI：子会话能取行，失败带着第几条', () async {
    if (_host.isEmpty) {
      markTestSkipped('未通过 --dart-define 提供连接信息');
      return;
    }
    final sessionId = await openSession(config: _config());

    final script = await editor.executeScript(
      sessionId: sessionId,
      sql: "SET @x = 6; SELECT @x * 7 AS answer; SELECT '订单;已完成' AS note",
      maxRows: BigInt.from(10),
    );
    expect(script.failure, isNull);
    expect(script.outcomes.length, 3);
    expect(script.outcomes[0].sessionId, isNull, reason: 'SET 没有结果集');
    final answer = await fetchWindow(sessionId: script.outcomes[1].sessionId!, offset: BigInt.zero, limit: BigInt.one);
    expect(answer.first.first, const CellValue.int(42), reason: '同一条连接上 @x 还在');
    final note = await fetchWindowText(sessionId: script.outcomes[2].sessionId!, offset: BigInt.zero, limit: BigInt.one);
    expect(note.first.first.text, '订单;已完成', reason: '字符串里的分号不切');

    final failed = await editor.executeScript(
      sessionId: sessionId,
      sql: 'SELECT 1; SELECT * FROM cdata_no_such_table',
      maxRows: BigInt.from(10),
    );
    expect(failed.failure!.index, 1);

    final plan = await editor.explain(sessionId: sessionId, sql: 'SELECT * FROM big_rows WHERE id = 1', maxRows: BigInt.from(10));
    expect(plan.summary!.columns.map((c) => c.name), contains('select_type'));

    await closeSession(sessionId: sessionId);
  });
}
