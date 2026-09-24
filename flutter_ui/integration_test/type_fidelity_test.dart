// 类型保真的跨 FFI 回归测试。
//
// cdata-core 里已经测过映射规则，这里测的是另一件事：值穿过 FFI 到 Dart 之后有没有变形。
// u64 上界、DECIMAL 文本、零日期这三条是最容易在这一跳出问题的。
//
// 运行：见 integration_test/all_test.dart

import 'dart:typed_data';

import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rust_init.dart';

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
}
