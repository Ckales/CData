import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Uint64List;

import 'src/rust/api/db.dart';
// 顶层函数和下面 GridSource 的同名方法重名，方法体里直接调会解析成方法自己
import 'src/rust/api/db.dart' as db show insertRow, deleteRows;
import 'src/rust/api/schema.dart';
import 'src/rust/api/value.dart';

/// 界面取数据的来源。
///
/// 生产环境是下面的 Rust 实现，测试里换成内存实现 —— UI 测试因此不用起 app、
/// 不用连库，跑在普通 `flutter test` 里就是秒级。
/// 真库行为由 cdata-core 的 Rust 测试保证，两边职责不重叠。
abstract class GridSource {
  QuerySummary get summary;

  /// 一屏的显示文本
  Future<List<List<String>>> windowText(int offset, int limit);

  /// 某一行的原始值，编辑时要用它判断类型
  Future<List<CellValue>> row(int index);

  Future<void> edit(int rowIndex, int columnIndex, CellValue value);

  /// 插一行，返回新的总行数。values[i] 为 null 表示这一列交给 DEFAULT / 自增
  Future<int> insertRow(List<CellValue?> values);

  /// 在一个事务里删若干行，返回新的总行数
  Future<int> deleteRows(List<int> rowIndexes);
}

abstract class SchemaSource {
  Future<List<String>> databases();
  Future<List<TableInfo>> tables(String database);
}

class RustGridSource implements GridSource {
  final BigInt sessionId;
  @override
  final QuerySummary summary;

  const RustGridSource({required this.sessionId, required this.summary});

  @override
  Future<List<List<String>>> windowText(int offset, int limit) {
    return fetchWindowText(
      sessionId: sessionId,
      offset: BigInt.from(offset),
      limit: BigInt.from(limit),
    );
  }

  @override
  Future<List<CellValue>> row(int index) async {
    final rows = await fetchWindow(
      sessionId: sessionId,
      offset: BigInt.from(index),
      limit: BigInt.one,
    );
    // 行越界时上层不该继续往下走，给空列表让调用方自己判断
    return rows.isEmpty ? const [] : rows.first;
  }

  @override
  Future<void> edit(int rowIndex, int columnIndex, CellValue value) {
    return applyEdit(
      sessionId: sessionId,
      rowIndex: BigInt.from(rowIndex),
      columnIndex: BigInt.from(columnIndex),
      newValue: value,
    );
  }

  @override
  Future<int> insertRow(List<CellValue?> values) async {
    final total = await db.insertRow(sessionId: sessionId, values: values);
    return total.toInt();
  }

  @override
  Future<int> deleteRows(List<int> rowIndexes) async {
    // FRB 的 Uint64List 元素是 BigInt，没有 fromList，只能先开长度再逐个填
    final indexes = Uint64List(rowIndexes.length);
    for (var i = 0; i < rowIndexes.length; i++) {
      indexes[i] = BigInt.from(rowIndexes[i]);
    }
    final total = await db.deleteRows(sessionId: sessionId, rowIndexes: indexes);
    return total.toInt();
  }
}

class RustSchemaSource implements SchemaSource {
  final BigInt sessionId;

  const RustSchemaSource(this.sessionId);

  @override
  Future<List<String>> databases() => listDatabases(sessionId: sessionId);

  @override
  Future<List<TableInfo>> tables(String database) {
    return listTables(sessionId: sessionId, database: database);
  }
}
