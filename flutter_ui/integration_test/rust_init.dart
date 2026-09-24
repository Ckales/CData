import 'package:cdata_flutter/src/rust/frb_generated.dart';

bool _initialized = false;

/// 合并跑多个测试文件时会被调用多次，RustLib.init 重复调用会抛异常
Future<void> ensureRustInit() async {
  if (_initialized) return;
  await RustLib.init();
  _initialized = true;
}
