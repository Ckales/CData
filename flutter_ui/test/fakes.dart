// UI 测试用的内存数据源。
//
// 真库行为由 cdata-core 的 Rust 测试保证；这里只喂固定数据给界面，
// 让 widget 测试不用起 app、不用连库。

import 'package:cdata_flutter/data_source.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/schema.dart';
import 'package:cdata_flutter/src/rust/api/value.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'dart:typed_data' show Uint8List;

/// FRB 的 Uint64List 元素是 BigInt，没有 fromList，只能先开长度再逐个填
Uint64List keyIndexes(List<int> indexes) {
  final list = Uint64List(indexes.length);
  for (var i = 0; i < indexes.length; i++) {
    list[i] = BigInt.from(indexes[i]);
  }
  return list;
}

/// 造 n 个字节，测二进制单元格用
Uint8List bytesOf(int length) => Uint8List(length);

ColumnMeta column(String name, {String table = 'orders', bool isBinary = false}) {
  return ColumnMeta(
    name: name,
    orgName: name,
    orgTable: table,
    schema: 'shop',
    isBinary: isBinary,
  );
}

QuerySummary summaryOf({
  required List<ColumnMeta> columns,
  required int totalRows,
  bool truncated = false,
  Editability? editability,
}) {
  return QuerySummary(
    columns: columns,
    totalRows: BigInt.from(totalRows),
    truncated: truncated,
    editability: editability ??
        Editability.editable(
          EditTarget(schema: 'shop', table: 'orders', keyIndexes: keyIndexes([0])),
        ),
  );
}

/// 内存网格数据源。记录收到的编辑，供断言检查
class FakeGridSource implements GridSource {
  @override
  final QuerySummary summary;

  final List<List<CellValue>> rows;

  /// 写回的调用记录：(行, 列, 值)
  final List<(int, int, CellValue)> edits = [];

  /// 插入的调用记录。null 表示那一列交给 DEFAULT
  final List<List<CellValue?>> inserts = [];

  /// 删除的调用记录
  final List<List<int>> deletes = [];

  /// 设成非 null 就让 edit / insertRow / deleteRows 抛错，用来测界面怎么显示失败
  String? editError;

  FakeGridSource({required this.summary, required this.rows});

  /// 造一个 n 行的表格：id / name 两列
  factory FakeGridSource.rows(int count, {Editability? editability}) {
    final rows = <List<CellValue>>[];
    for (var i = 1; i <= count; i++) {
      rows.add([CellValue.int(i), CellValue.text('用户$i')]);
    }
    return FakeGridSource(
      summary: summaryOf(
        columns: [column('id'), column('name')],
        totalRows: count,
        editability: editability,
      ),
      rows: rows,
    );
  }

  @override
  Future<List<List<String>>> windowText(int offset, int limit) async {
    final start = offset.clamp(0, rows.length);
    final end = (start + limit).clamp(0, rows.length);

    final out = <List<String>>[];
    for (final row in rows.sublist(start, end)) {
      final texts = <String>[];
      for (final cell in row) {
        texts.add(_display(cell));
      }
      out.add(texts);
    }
    return out;
  }

  @override
  Future<List<CellValue>> row(int index) async {
    if (index < 0 || index >= rows.length) return const [];
    return rows[index];
  }

  @override
  Future<void> edit(int rowIndex, int columnIndex, CellValue value) async {
    final error = editError;
    if (error != null) throw Exception(error);

    edits.add((rowIndex, columnIndex, value));
    rows[rowIndex][columnIndex] = value;
  }

  @override
  Future<int> insertRow(List<CellValue?> values) async {
    final error = editError;
    if (error != null) throw Exception(error);

    inserts.add(values);
    // 假装库里的 DEFAULT 是 NULL。真实回读行为由 cdata-core 的真库测试保证
    final row = <CellValue>[];
    for (final value in values) {
      row.add(value ?? const CellValue.null_());
    }
    rows.add(row);
    return rows.length;
  }

  @override
  Future<int> deleteRows(List<int> rowIndexes) async {
    final error = editError;
    if (error != null) throw Exception(error);

    deletes.add(rowIndexes);
    final sorted = [...rowIndexes]..sort();
    for (final index in sorted.reversed) {
      rows.removeAt(index);
    }
    return rows.length;
  }

  /// 和 Rust 侧 display_text 保持一致的显示规则
  String _display(CellValue cell) {
    return switch (cell) {
      CellValue_Null() => 'NULL',
      CellValue_Int(:final field0) => field0.toString(),
      CellValue_UInt(:final field0) => field0.toString(),
      CellValue_Double(:final field0) => field0.toString(),
      CellValue_Text(:final field0) => field0,
      CellValue_Bytes(:final field0) => '<二进制 ${field0.length} 字节>',
      CellValue_InvalidText(:final field0) => '<无法解码 ${field0.length} 字节>',
    };
  }
}

class FakeSchemaSource implements SchemaSource {
  final List<String> dbs;
  final Map<String, List<TableInfo>> tablesByDb;

  FakeSchemaSource({required this.dbs, required this.tablesByDb});

  factory FakeSchemaSource.simple() {
    return FakeSchemaSource(
      dbs: ['shop', 'analytics'],
      tablesByDb: {
        'shop': [
          TableInfo(name: 'orders', estimatedRows: BigInt.from(1200), isView: false),
          TableInfo(name: 'order_items', estimatedRows: BigInt.from(8400), isView: false),
          TableInfo(name: 'users', estimatedRows: BigInt.from(300), isView: false),
          TableInfo(name: 'v_daily', estimatedRows: BigInt.zero, isView: true),
        ],
        'analytics': [],
      },
    );
  }

  @override
  Future<List<String>> databases() async => dbs;

  @override
  Future<List<TableInfo>> tables(String database) async => tablesByDb[database] ?? [];
}
