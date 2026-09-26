import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Uint64List;

import 'src/rust/api/csv_import.dart';
import 'src/rust/api/csv_import.dart' as csv_import show suggestMapping;
import 'src/rust/api/db.dart';
// 顶层函数和下面 GridSource 的同名方法重名，方法体里直接调会解析成方法自己
import 'src/rust/api/db.dart' as db
    show refreshRow, insertRow, deleteRows, copyRange, parseClipboard, pasteCells, columnChoices, exportRows;
import 'src/rust/api/layouts.dart';
import 'src/rust/api/layouts.dart' as layouts show loadLayout, saveLayout;
import 'src/rust/api/schema.dart';
import 'src/rust/api/schema.dart' as schema
    show
        tableDraft,
        previewAlter,
        applyAlter,
        newTableDraft,
        previewCreateTable,
        createTable,
        previewTableAction,
        applyTableAction,
        countRows,
        runMaintenance,
        insertTemplate;
import 'src/rust/api/value.dart';
import 'src/rust/api/value.dart' as value show formatJson, hexDump;
import 'dart:typed_data' show Uint8List;

/// 界面取数据的来源。
///
/// 生产环境是下面的 Rust 实现，测试里换成内存实现 —— UI 测试因此不用起 app、
/// 不用连库，跑在普通 `flutter test` 里就是秒级。
/// 真库行为由 cdata-core 的 Rust 测试保证，两边职责不重叠。
abstract class GridSource {
  QuerySummary get summary;

  /// 一屏的显示文本，带着「是不是占位」
  Future<List<List<DisplayCell>>> windowText(int offset, int limit);

  /// 某一行的原始值，编辑时要用它判断类型
  Future<List<CellValue>> row(int index);

  Future<void> edit(int rowIndex, int columnIndex, CellValue value);

  /// 按主键从库里重读一行。库里找不到这一行就抛错
  Future<void> refreshRow(int rowIndex);

  /// 插一行，返回新的总行数。values[i] 为 null 表示这一列交给 DEFAULT / 自增
  Future<int> insertRow(List<CellValue?> values);

  /// 在一个事务里删若干行，返回新的总行数
  Future<int> deleteRows(List<int> rowIndexes);

  /// 这个结果集记住的列宽列序。没记过、或结果集不来自单张表，都是空列表
  Future<List<ColumnLayout>> loadLayout();

  Future<void> saveLayout(List<ColumnLayout> columns);

  /// 一片单元格编码成 TSV。columns 按显示顺序给，行可以不在当前窗口里
  Future<String> copyRange(int rowStart, int rowCount, List<int> columns);

  /// 解析剪贴板文本。不带引号的 NULL 是 NULL，其余都是文本
  Future<List<List<CellValue>>> parseClipboard(String text);

  /// 从 rowStart 起把一块值粘进这几列，返回写了多少格
  Future<int> pasteCells(int rowStart, List<int> columns, List<List<CellValue>> values);

  /// ENUM / SET 列的可选值，按定义顺序
  Future<List<String>> columnChoices(int column);

  /// 格式化 JSON，同时校验，不合法抛错
  Future<String> formatJson(String text);

  /// 二进制内容的十六进制视图
  Future<String> hexDump(Uint8List bytes);

  /// 把一段行写成文件。rowCount 为 null 表示到末尾，columns 按导出顺序
  Future<ExportSummary> exportRows(
    String path,
    int rowStart,
    int? rowCount,
    List<int> columns,
    ExportOptions options,
  );
}

/// FRB 的 Uint64List 元素是 BigInt，没有 fromList，只能先开长度再逐个填
Uint64List _u64List(List<int> values) {
  final list = Uint64List(values.length);
  for (var i = 0; i < values.length; i++) {
    list[i] = BigInt.from(values[i]);
  }
  return list;
}

abstract class SchemaSource {
  Future<List<String>> databases();
  Future<List<TableInfo>> tables(String database);

  /// 列、索引、外键和建表语句，一次取齐
  Future<TableStructure> structure(String database, String table);

  /// 结构转成可编辑的草稿。哪些列、索引锁住（只能删除或改名）由 core 判定
  TableDraft draftOf(TableStructure structure);

  /// 预览一批结构改动：core 生成的语句、危险操作、执行须知
  Future<AlterPlan> previewAlter(String database, String table, TableStructure original, TableDraft draft);

  /// 执行预览过的改动。statements 是预览时拿到的语句，core 重新生成的不一致就拒绝
  Future<void> applyAlter(
    String database,
    String table,
    TableStructure original,
    TableDraft draft,
    List<String> statements,
  );

  /// 新建表的起始草稿，默认值由 core 定
  TableDraft newTableDraft();

  /// 预览新建表。同名的表或视图已经存在就抛错
  Future<AlterPlan> previewCreateTable(String database, String table, TableDraft draft);

  /// 执行预览过的建表。statements 是预览时拿到的语句，core 重新生成的不一致就拒绝
  Future<void> createTable(String database, String table, TableDraft draft, List<String> statements);

  /// 预览侧栏右键的表操作（改名、复制、删除、清空）。是表还是视图由 core 自己查
  Future<AlterPlan> previewTableAction(String database, String table, TableAction action);

  /// 执行预览过的表操作。statements 是预览时拿到的语句，core 重新生成的不一致就拒绝
  Future<void> applyTableAction(String database, String table, TableAction action, List<String> statements);

  /// 精确行数（真的 COUNT(*)）
  Future<int> countRows(String database, String table);

  /// ANALYZE / CHECK / OPTIMIZE / REPAIR TABLE 的结果消息
  Future<List<MaintenanceMessage>> runMaintenance(String database, String table, Maintenance op);

  /// INSERT 模板，列名写全、值用 ? 占位
  Future<String> insertTemplate(String database, String table);
}

class RustGridSource implements GridSource {
  final BigInt sessionId;
  @override
  final QuerySummary summary;

  const RustGridSource({required this.sessionId, required this.summary});

  @override
  Future<List<List<DisplayCell>>> windowText(int offset, int limit) {
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
  Future<void> refreshRow(int rowIndex) {
    return db.refreshRow(sessionId: sessionId, rowIndex: BigInt.from(rowIndex));
  }

  @override
  Future<int> insertRow(List<CellValue?> values) async {
    final total = await db.insertRow(sessionId: sessionId, values: values);
    return total.toInt();
  }

  @override
  Future<int> deleteRows(List<int> rowIndexes) async {
    final total = await db.deleteRows(sessionId: sessionId, rowIndexes: _u64List(rowIndexes));
    return total.toInt();
  }

  @override
  Future<List<ColumnLayout>> loadLayout() async {
    final key = summary.layoutKey;
    // JOIN、表达式结果没有布局键，不记
    if (key == null) return const [];
    return layouts.loadLayout(key: key);
  }

  @override
  Future<void> saveLayout(List<ColumnLayout> columns) async {
    final key = summary.layoutKey;
    if (key == null) return;
    await layouts.saveLayout(key: key, columns: columns);
  }

  @override
  Future<String> copyRange(int rowStart, int rowCount, List<int> columns) {
    return db.copyRange(
      sessionId: sessionId,
      rowStart: BigInt.from(rowStart),
      rowCount: BigInt.from(rowCount),
      columnIndexes: _u64List(columns),
    );
  }

  @override
  Future<List<List<CellValue>>> parseClipboard(String text) => db.parseClipboard(text: text);

  @override
  Future<List<String>> columnChoices(int column) {
    return db.columnChoices(sessionId: sessionId, columnIndex: BigInt.from(column));
  }

  @override
  Future<String> formatJson(String text) => value.formatJson(text: text);

  @override
  Future<ExportSummary> exportRows(
    String path,
    int rowStart,
    int? rowCount,
    List<int> columns,
    ExportOptions options,
  ) {
    return db.exportRows(
      sessionId: sessionId,
      path: path,
      rowStart: BigInt.from(rowStart),
      rowCount: rowCount == null ? null : BigInt.from(rowCount),
      columnIndexes: _u64List(columns),
      options: options,
    );
  }

  /// 十六进制视图最多看前 64KB，再大交给导出
  @override
  Future<String> hexDump(Uint8List bytes) => value.hexDump(bytes: bytes, limit: BigInt.from(65536));

  @override
  Future<int> pasteCells(int rowStart, List<int> columns, List<List<CellValue>> values) async {
    final written = await db.pasteCells(
      sessionId: sessionId,
      rowStart: BigInt.from(rowStart),
      columnIndexes: _u64List(columns),
      values: values,
    );
    return written.toInt();
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

  @override
  Future<TableStructure> structure(String database, String table) {
    return tableStructure(sessionId: sessionId, database: database, table: table);
  }

  @override
  TableDraft draftOf(TableStructure structure) => schema.tableDraft(structure: structure);

  @override
  Future<AlterPlan> previewAlter(String database, String table, TableStructure original, TableDraft draft) {
    return schema.previewAlter(
      sessionId: sessionId,
      database: database,
      table: table,
      original: original,
      draft: draft,
    );
  }

  @override
  Future<void> applyAlter(
    String database,
    String table,
    TableStructure original,
    TableDraft draft,
    List<String> statements,
  ) {
    return schema.applyAlter(
      sessionId: sessionId,
      database: database,
      table: table,
      original: original,
      draft: draft,
      statements: statements,
    );
  }

  @override
  TableDraft newTableDraft() => schema.newTableDraft();

  @override
  Future<AlterPlan> previewCreateTable(String database, String table, TableDraft draft) {
    return schema.previewCreateTable(sessionId: sessionId, database: database, table: table, draft: draft);
  }

  @override
  Future<void> createTable(String database, String table, TableDraft draft, List<String> statements) {
    return schema.createTable(
      sessionId: sessionId,
      database: database,
      table: table,
      draft: draft,
      statements: statements,
    );
  }

  @override
  Future<AlterPlan> previewTableAction(String database, String table, TableAction action) {
    return schema.previewTableAction(sessionId: sessionId, database: database, table: table, action: action);
  }

  @override
  Future<void> applyTableAction(String database, String table, TableAction action, List<String> statements) {
    return schema.applyTableAction(
      sessionId: sessionId,
      database: database,
      table: table,
      action: action,
      statements: statements,
    );
  }

  @override
  Future<int> countRows(String database, String table) async {
    final count = await schema.countRows(sessionId: sessionId, database: database, table: table);
    return count.toInt();
  }

  @override
  Future<List<MaintenanceMessage>> runMaintenance(String database, String table, Maintenance op) {
    return schema.runMaintenance(sessionId: sessionId, database: database, table: table, op: op);
  }

  @override
  Future<String> insertTemplate(String database, String table) {
    return schema.insertTemplate(sessionId: sessionId, database: database, table: table);
  }
}

/// 导入 CSV 用的数据源。解析、映射校验、写库都在 Rust 侧，界面只传选项、显示结果
abstract class ImportSource {
  /// 目标表的列（能不能写、要不要必填）和当前 sql_mode
  Future<ImportTarget> target(String database, String table);

  /// 读前 limit 行，表头不算在内
  Future<CsvPreview> preview(String path, ImportOptions options, int limit);

  /// 按表头建议的映射：下标是 CSV 列，值是目标列下标，null 是跳过
  List<int?> suggestMapping(List<String> header, List<TargetColumn> columns);

  /// 在后台开始导入，返回任务 id。映射不对、文件打不开直接抛错
  Future<int> start(ImportRequest request);

  /// 进度；结束后是报告
  Future<ImportStatus> status(int job);

  Future<void> cancel(int job);

  /// 失败的行另存成 CSV，返回行数
  Future<int> saveErrors(int job, String path);

  /// 关掉任务、删掉错误行临时文件
  Future<void> close(int job);
}

class RustImportSource implements ImportSource {
  final BigInt sessionId;

  const RustImportSource(this.sessionId);

  @override
  Future<ImportTarget> target(String database, String table) {
    return prepareImport(sessionId: sessionId, database: database, table: table);
  }

  @override
  Future<CsvPreview> preview(String path, ImportOptions options, int limit) {
    return previewCsv(path: path, options: options, limit: BigInt.from(limit));
  }

  @override
  List<int?> suggestMapping(List<String> header, List<TargetColumn> columns) {
    return csv_import.suggestMapping(header: header, columns: columns);
  }

  @override
  Future<int> start(ImportRequest request) async {
    final job = await startImport(sessionId: sessionId, request: request);
    return job.toInt();
  }

  @override
  Future<ImportStatus> status(int job) => importStatus(jobId: BigInt.from(job));

  @override
  Future<void> cancel(int job) => cancelImport(jobId: BigInt.from(job));

  @override
  Future<int> saveErrors(int job, String path) async {
    final rows = await saveImportErrors(jobId: BigInt.from(job), path: path);
    return rows.toInt();
  }

  @override
  Future<void> close(int job) => closeImport(jobId: BigInt.from(job));
}
