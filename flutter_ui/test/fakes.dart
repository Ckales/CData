// UI 测试用的内存数据源。
//
// 真库行为由 cdata-core 的 Rust 测试保证；这里只喂固定数据给界面，
// 让 widget 测试不用起 app、不用连库。

import 'package:cdata_flutter/data_source.dart';
import 'package:cdata_flutter/src/rust/api/csv_import.dart';
import 'package:cdata_flutter/src/rust/api/db.dart';
import 'package:cdata_flutter/src/rust/api/layouts.dart';
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

ColumnMeta column(
  String name, {
  String table = 'orders',
  bool isBinary = false,
  ColumnKind kind = ColumnKind.text,
  int decimals = 0,
}) {
  return ColumnMeta(
    name: name,
    orgName: name,
    orgTable: table,
    schema: 'shop',
    isBinary: isBinary,
    kind: isBinary ? ColumnKind.binary : kind,
    decimals: decimals,
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

  /// 记住的列布局。saveLayout 会覆盖它
  List<ColumnLayout> savedLayout = [];

  /// saveLayout 的调用记录
  final List<List<ColumnLayout>> layoutSaves = [];

  /// copyRange 的调用记录：(起始行, 行数, 列)
  final List<(int, int, List<int>)> copies = [];

  /// pasteCells 的调用记录：(起始行, 列, 值)
  final List<(int, List<int>, List<List<CellValue>>)> pastes = [];

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
  Future<List<List<DisplayCell>>> windowText(int offset, int limit) async {
    final start = offset.clamp(0, rows.length);
    final end = (start + limit).clamp(0, rows.length);

    final out = <List<DisplayCell>>[];
    for (final row in rows.sublist(start, end)) {
      final texts = <DisplayCell>[];
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

  @override
  Future<List<ColumnLayout>> loadLayout() async => savedLayout;

  @override
  Future<void> saveLayout(List<ColumnLayout> columns) async {
    layoutSaves.add(columns);
    savedLayout = columns;
  }

  /// 简化版编码：只拼显示文本。真实的引号、NULL、二进制规则由 cdata-core 的测试保证
  @override
  Future<String> copyRange(int rowStart, int rowCount, List<int> columns) async {
    copies.add((rowStart, rowCount, columns));
    final lines = <String>[];
    for (final row in rows.sublist(rowStart, rowStart + rowCount)) {
      final fields = <String>[];
      for (final column in columns) {
        fields.add(_display(row[column]).text);
      }
      lines.add(fields.join('\t'));
    }
    return lines.join('\n');
  }

  @override
  Future<List<List<CellValue>>> parseClipboard(String text) async {
    final parsed = <List<CellValue>>[];
    for (final line in text.trimRight().split('\n')) {
      final values = <CellValue>[];
      for (final field in line.split('\t')) {
        values.add(field == 'NULL' ? const CellValue.null_() : CellValue.text(field));
      }
      parsed.add(values);
    }
    return parsed;
  }

  @override
  Future<int> pasteCells(int rowStart, List<int> columns, List<List<CellValue>> values) async {
    final error = editError;
    if (error != null) throw Exception(error);

    pastes.add((rowStart, columns, values));
    var written = 0;
    for (var r = 0; r < values.length; r++) {
      for (var c = 0; c < columns.length; c++) {
        rows[rowStart + r][columns[c]] = values[r][c];
        written++;
      }
    }
    return written;
  }

  /// 列下标 → ENUM / SET 可选值
  final Map<int, List<String>> choices = {};

  @override
  Future<List<String>> columnChoices(int column) async {
    final list = choices[column];
    if (list == null) throw Exception('列 $column 不是 ENUM / SET');
    return list;
  }

  /// 简化版：只认对象和数组的外形。真实的校验和格式化由 cdata-core 的测试保证
  @override
  Future<String> formatJson(String text) async {
    final trimmed = text.trim();
    final looksLikeJson = (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'));
    if (!looksLikeJson) throw Exception('不是合法的 JSON：line 1');
    // 和真实格式化一样是幂等的：格式化过的文本再校验一次也得通过
    return '${trimmed.substring(0, 1)}\n${trimmed.substring(1).trimLeft()}';
  }

  @override
  Future<String> hexDump(Uint8List bytes) async => 'HEX ${bytes.length}';

  /// exportRows 的调用记录
  final List<({String path, int rowStart, int? rowCount, List<int> columns, ExportOptions options})>
      exports = [];

  /// 导出时假装结果集被截断过
  bool exportTruncated = false;

  @override
  Future<ExportSummary> exportRows(
    String path,
    int rowStart,
    int? rowCount,
    List<int> columns,
    ExportOptions options,
  ) async {
    final error = editError;
    if (error != null) throw Exception(error);

    exports.add((path: path, rowStart: rowStart, rowCount: rowCount, columns: columns, options: options));
    final written = rowCount ?? rows.length - rowStart;
    return ExportSummary(rowsWritten: BigInt.from(written), sourceTruncated: exportTruncated);
  }

  /// 和 Rust 侧 display_cell 保持一致的显示规则
  DisplayCell _display(CellValue cell) {
    return switch (cell) {
      CellValue_Null() => const DisplayCell(text: 'NULL', placeholder: true),
      CellValue_Int(:final field0) => DisplayCell(text: field0.toString(), placeholder: false),
      CellValue_UInt(:final field0) => DisplayCell(text: field0.toString(), placeholder: false),
      CellValue_Double(:final field0) => DisplayCell(text: field0.toString(), placeholder: false),
      CellValue_Text(:final field0) => DisplayCell(text: field0, placeholder: false),
      CellValue_Bytes(:final field0) => DisplayCell(text: '<二进制 ${field0.length} 字节>', placeholder: true),
      CellValue_InvalidText(:final field0) => DisplayCell(text: '<无法解码 ${field0.length} 字节>', placeholder: true),
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

  /// 表名 → 结构。没有的表 structure 会抛错，用来测失败提示
  final Map<String, TableStructure> structures = {};

  /// structure 被调了几次，测执行后是否重读
  int structureLoads = 0;

  @override
  Future<TableStructure> structure(String database, String table) async {
    structureLoads++;
    final structure = structures[table];
    if (structure == null) throw Exception('表 $table 不存在');
    return structure;
  }

  /// 给了就原样返回，测锁定列用；没给按结构直接转，不判锁定（锁定规则由 core 的测试保证）
  TableDraft? draft;

  @override
  TableDraft draftOf(TableStructure structure) {
    final configured = draft;
    if (configured != null) return configured;
    return TableDraft(
      columns: [
        for (final column in structure.columns)
          ColumnDraft(
            originalName: column.name,
            name: column.name,
            columnType: column.columnType,
            nullable: column.nullable,
            default_: column.default_,
            autoIncrement: column.extra.contains('auto_increment'),
            comment: column.comment,
            collation: column.collation,
          ),
      ],
      indexes: [
        for (final index in structure.indexes)
          IndexDraft(
            originalName: index.name,
            name: index.name,
            kind: index.name == 'PRIMARY'
                ? IndexKind.primary
                : (index.unique ? IndexKind.unique : IndexKind.normal),
            parts: index.parts,
            comment: index.comment,
          ),
      ],
      foreignKeys: [
        for (final fk in structure.foreignKeys)
          ForeignKeyDraft(
            originalName: fk.name,
            name: fk.name,
            columns: fk.columns,
            referencedSchema: fk.referencedSchema,
            referencedTable: fk.referencedTable,
            referencedColumns: fk.referencedColumns,
            onUpdate: fk.onUpdate,
            onDelete: fk.onDelete,
          ),
      ],
      checks: [
        for (final check in structure.checks ?? const <CheckDef>[])
          CheckDraft(originalName: check.name, name: check.name, expression: check.expression, enforced: check.enforced),
      ],
      options: TableOptionsDraft(
        engine: structure.engine ?? '',
        charset: structure.tableCharset,
        collation: structure.tableCollation,
        comment: structure.tableComment,
        rowFormat: structure.rowFormat,
        convertCharset: false,
      ),
    );
  }

  /// 和 core 的 new_table_draft 一样的起点：自增主键 id、InnoDB
  @override
  TableDraft newTableDraft() {
    return const TableDraft(
      columns: [
        ColumnDraft(
          name: 'id',
          columnType: 'int unsigned',
          nullable: false,
          default_: DefaultValue.noDefault(),
          autoIncrement: true,
          comment: '',
        ),
      ],
      indexes: [
        IndexDraft(
          name: 'PRIMARY',
          kind: IndexKind.primary,
          parts: [IndexPart(column: 'id', descending: false)],
          comment: '',
        ),
      ],
      foreignKeys: [],
      checks: [],
      options: TableOptionsDraft(engine: 'InnoDB', comment: '', convertCharset: false),
    );
  }

  /// 收到的新建表预览（表名、草稿）和执行的建表语句
  final List<(String, TableDraft)> createPreviews = [];
  final List<(String, List<String>)> created = [];

  @override
  Future<AlterPlan> previewCreateTable(String database, String table, TableDraft draft) async {
    createPreviews.add((table, draft));
    final error = previewError;
    if (error != null) throw error;
    return plan;
  }

  @override
  Future<void> createTable(String database, String table, TableDraft draft, List<String> statements) async {
    final error = applyError;
    if (error != null) throw error;
    created.add((table, statements));
  }

  /// 预览返回的计划；previewError 不为空时预览抛它
  AlterPlan plan = const AlterPlan(statements: ['ALTER TABLE `shop`.`posts`\n  RENAME COLUMN `a` TO `b`'], dangers: [], notes: []);
  Object? previewError;
  Object? applyError;

  /// 收到的预览草稿、执行的语句
  final List<TableDraft> previews = [];
  final List<List<String>> applied = [];

  @override
  Future<AlterPlan> previewAlter(String database, String table, TableStructure original, TableDraft draft) async {
    previews.add(draft);
    final error = previewError;
    if (error != null) throw error;
    return plan;
  }

  @override
  Future<void> applyAlter(
    String database,
    String table,
    TableStructure original,
    TableDraft draft,
    List<String> statements,
  ) async {
    final error = applyError;
    if (error != null) throw error;
    applied.add(statements);
  }
}

TargetColumn targetColumn(
  String name, {
  bool mandatory = false,
  bool generated = false,
  bool autoIncrement = false,
}) {
  return TargetColumn(
    name: name,
    columnType: 'varchar(20)',
    nullable: !mandatory && !autoIncrement,
    autoIncrement: autoIncrement,
    isBinary: false,
    generated: generated,
    mandatory: mandatory,
  );
}

ImportProgress importProgress({int read = 0, int inserted = 0, int failed = 0, int bytes = 0, int total = 100}) {
  return ImportProgress(
    bytesRead: BigInt.from(bytes),
    totalBytes: BigInt.from(total),
    rowsRead: BigInt.from(read),
    rowsInserted: BigInt.from(inserted),
    rowsFailed: BigInt.from(failed),
  );
}

/// 内存导入数据源。解析、映射校验、写库的真实规则由 cdata-core 的测试保证，这里只按剧本回放
class FakeImportSource implements ImportSource {
  ImportTarget targetResult;
  String? targetError;

  CsvPreview previewResult;

  /// preview 的调用记录：(路径, 选项)
  final List<(String, ImportOptions)> previews = [];

  final List<ImportRequest> starts = [];

  /// 设成非 null 就让 start 抛错，模拟 core 拒绝映射
  String? startError;

  /// status 依次返回的状态，用完后一直返回最后一个
  List<ImportStatus> statuses;
  int statusCalls = 0;

  final List<int> cancels = [];
  final List<int> closes = [];
  final List<(int, String)> saves = [];

  FakeImportSource({required this.targetResult, required this.previewResult, required this.statuses});

  @override
  Future<ImportTarget> target(String database, String table) async {
    final error = targetError;
    if (error != null) throw Exception(error);
    return targetResult;
  }

  @override
  Future<CsvPreview> preview(String path, ImportOptions options, int limit) async {
    previews.add((path, options));
    return previewResult;
  }

  /// 简化版：名字完全相同才对上
  @override
  List<int?> suggestMapping(List<String> header, List<TargetColumn> columns) {
    final mapping = <int?>[];
    for (final name in header) {
      final index = columns.indexWhere((column) => column.name == name && !column.generated);
      mapping.add(index < 0 ? null : index);
    }
    return mapping;
  }

  @override
  Future<int> start(ImportRequest request) async {
    final error = startError;
    if (error != null) throw Exception(error);
    starts.add(request);
    return 7;
  }

  @override
  Future<ImportStatus> status(int job) async {
    final index = statusCalls < statuses.length ? statusCalls : statuses.length - 1;
    statusCalls++;
    return statuses[index];
  }

  @override
  Future<void> cancel(int job) async {
    cancels.add(job);
    statuses = [ImportStatus.finished(ImportReport(
      progress: importProgress(read: 1, inserted: 0),
      outcome: const ImportOutcome.stopped('已取消。没有提交任何行'),
      errors: const [],
    ))];
    statusCalls = 0;
  }

  @override
  Future<int> saveErrors(int job, String path) async {
    saves.add((job, path));
    return 2;
  }

  @override
  Future<void> close(int job) async => closes.add(job);
}
