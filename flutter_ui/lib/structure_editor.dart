import 'package:flutter/material.dart';

import 'data_source.dart';
import 'mac_widgets.dart';
import 'src/rust/api/schema.dart';

/// 表结构编辑器。改动先攒在界面里，预览 core 生成的 DDL 确认后才执行。
/// 执行成功返回 true，调用方据此重读结构
Future<bool> showStructureEditor(
  BuildContext context, {
  required SchemaSource source,
  required String database,
  required String table,
  required TableStructure structure,
}) async {
  final applied = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _EditorDialog(source: source, database: database, table: table, structure: structure),
  );
  return applied != null;
}

/// 新建表：同一个编辑器，草稿从 core 的起始草稿开始，生成 CREATE TABLE。
/// 建成返回表名，取消返回 null
Future<String?> showTableCreator(
  BuildContext context, {
  required SchemaSource source,
  required String database,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _EditorDialog(source: source, database: database, table: null, structure: null),
  );
}

enum _DefaultKind { none, null_, literal, expression }

const _defaultKindLabels = {
  _DefaultKind.none: '无默认值',
  _DefaultKind.null_: 'NULL',
  _DefaultKind.literal: '字面量',
  _DefaultKind.expression: '表达式',
};

const _indexKindLabels = {
  IndexKind.primary: 'PRIMARY',
  IndexKind.unique: 'UNIQUE',
  IndexKind.normal: 'INDEX',
  IndexKind.fulltext: 'FULLTEXT',
  IndexKind.spatial: 'SPATIAL',
};

const _foreignKeyActions = ['RESTRICT', 'CASCADE', 'SET NULL', 'NO ACTION', 'SET DEFAULT'];

/// 一列的编辑状态。索引和外键引用的是这个对象而不是列名，改名时自然跟着走
class _ColumnRow {
  final String? originalName;
  final String? locked;
  final TextEditingController name;
  final TextEditingController type;
  final TextEditingController defaultText;
  final TextEditingController onUpdate;
  final TextEditingController collation;
  final TextEditingController comment;
  bool nullable;
  bool autoIncrement;
  _DefaultKind defaultKind;

  _ColumnRow(ColumnDraft draft)
      : originalName = draft.originalName,
        locked = draft.locked,
        name = TextEditingController(text: draft.name),
        type = TextEditingController(text: draft.columnType),
        defaultText = TextEditingController(
          text: switch (draft.default_) {
            DefaultValue_Literal(:final field0) => field0,
            DefaultValue_Expression(:final field0) => field0,
            _ => '',
          },
        ),
        onUpdate = TextEditingController(text: draft.onUpdate ?? ''),
        collation = TextEditingController(text: draft.collation ?? ''),
        comment = TextEditingController(text: draft.comment),
        nullable = draft.nullable,
        autoIncrement = draft.autoIncrement,
        defaultKind = switch (draft.default_) {
          DefaultValue_NoDefault() => _DefaultKind.none,
          DefaultValue_Null() => _DefaultKind.null_,
          DefaultValue_Literal() => _DefaultKind.literal,
          DefaultValue_Expression() => _DefaultKind.expression,
        };

  DefaultValue get defaultValue => switch (defaultKind) {
        _DefaultKind.none => const DefaultValue.noDefault(),
        _DefaultKind.null_ => const DefaultValue.null_(),
        _DefaultKind.literal => DefaultValue.literal(defaultText.text),
        _DefaultKind.expression => DefaultValue.expression(defaultText.text),
      };

  void dispose() {
    for (final controller in [name, type, defaultText, onUpdate, collation, comment]) {
      controller.dispose();
    }
  }
}

class _PartRow {
  /// 函数索引的那一段没有列，是 null
  _ColumnRow? column;
  final TextEditingController prefix;
  bool descending;

  _PartRow(this.column, {int? prefix, this.descending = false})
      : prefix = TextEditingController(text: prefix?.toString() ?? '');
}

class _IndexRow {
  final String? originalName;
  final String? locked;
  final TextEditingController name;
  final TextEditingController comment;
  IndexKind kind;
  final List<_PartRow> parts;

  _IndexRow({
    required this.originalName,
    required this.locked,
    required String name,
    required String comment,
    required this.kind,
    required this.parts,
  })  : name = TextEditingController(text: name),
        comment = TextEditingController(text: comment);
}

class _ForeignKeyPair {
  _ColumnRow column;
  final TextEditingController referenced;

  _ForeignKeyPair(this.column, String referenced) : referenced = TextEditingController(text: referenced);
}

class _ForeignKeyRow {
  final String? originalName;
  final TextEditingController name;
  final TextEditingController referencedSchema;
  final TextEditingController referencedTable;
  final List<_ForeignKeyPair> pairs;
  String onUpdate;
  String onDelete;

  _ForeignKeyRow({
    required this.originalName,
    required String name,
    required String referencedSchema,
    required String referencedTable,
    required this.pairs,
    required this.onUpdate,
    required this.onDelete,
  })  : name = TextEditingController(text: name),
        referencedSchema = TextEditingController(text: referencedSchema),
        referencedTable = TextEditingController(text: referencedTable);
}

class _CheckRow {
  /// 原有的约束只能删，不能改
  final String? originalName;
  final TextEditingController name;
  final TextEditingController expression;
  bool enforced;

  _CheckRow(CheckDraft draft)
      : originalName = draft.originalName,
        name = TextEditingController(text: draft.name),
        expression = TextEditingController(text: draft.expression),
        enforced = draft.enforced;

  void dispose() {
    name.dispose();
    expression.dispose();
  }
}

class _EditorDialog extends StatefulWidget {
  final SchemaSource source;
  final String database;

  /// 新建表时 table 和 structure 都是 null
  final String? table;
  final TableStructure? structure;

  const _EditorDialog({required this.source, required this.database, required this.table, required this.structure});

  @override
  State<_EditorDialog> createState() => _EditorDialogState();
}

class _EditorDialogState extends State<_EditorDialog> {
  final List<_ColumnRow> _columns = [];
  final List<_IndexRow> _indexes = [];
  final List<_ForeignKeyRow> _foreignKeys = [];
  final List<_ColumnRow> _removedColumns = [];
  final List<_CheckRow> _checks = [];
  final List<_CheckRow> _removedChecks = [];
  final _tableName = TextEditingController();
  final _engine = TextEditingController();
  final _charset = TextEditingController();
  final _collation = TextEditingController();
  final _tableComment = TextEditingController();
  final _autoIncrement = TextEditingController();
  final _rowFormat = TextEditingController();
  bool _convertCharset = false;
  String? _error;
  bool _previewing = false;

  bool get _creating => widget.structure == null;

  @override
  void initState() {
    super.initState();
    final structure = widget.structure;
    final draft = structure == null ? widget.source.newTableDraft() : widget.source.draftOf(structure);
    final options = draft.options;
    _engine.text = options.engine;
    _charset.text = options.charset ?? '';
    _collation.text = options.collation ?? '';
    _tableComment.text = options.comment;
    _autoIncrement.text = options.autoIncrement?.toString() ?? '';
    _rowFormat.text = options.rowFormat ?? '';
    for (final check in draft.checks) {
      _checks.add(_CheckRow(check));
    }
    for (final column in draft.columns) {
      _columns.add(_ColumnRow(column));
    }
    for (final index in draft.indexes) {
      _indexes.add(_IndexRow(
        originalName: index.originalName,
        locked: index.locked,
        name: index.name,
        comment: index.comment,
        kind: index.kind,
        parts: [
          for (final part in index.parts)
            _PartRow(_columnNamed(part.column), prefix: part.prefix, descending: part.descending),
        ],
      ));
    }
    for (final fk in draft.foreignKeys) {
      _foreignKeys.add(_ForeignKeyRow(
        originalName: fk.originalName,
        name: fk.name,
        referencedSchema: fk.referencedSchema,
        referencedTable: fk.referencedTable,
        pairs: [
          for (var i = 0; i < fk.columns.length; i++)
            _ForeignKeyPair(_columnNamed(fk.columns[i])!, fk.referencedColumns[i]),
        ],
        onUpdate: fk.onUpdate,
        onDelete: fk.onDelete,
      ));
    }
  }

  /// 草稿里索引、外键按列名引用列。改表时是原列名；新建表的起始草稿没有原列名，按名字找
  _ColumnRow? _columnNamed(String? name) {
    if (name == null) return null;
    for (final column in _columns) {
      if ((column.originalName ?? column.name.text) == name) return column;
    }
    return null;
  }

  @override
  void dispose() {
    for (final column in [..._columns, ..._removedColumns]) {
      column.dispose();
    }
    for (final check in [..._checks, ..._removedChecks]) {
      check.dispose();
    }
    for (final controller in [_tableName, _engine, _charset, _collation, _tableComment, _autoIncrement, _rowFormat]) {
      controller.dispose();
    }
    for (final index in _indexes) {
      index.name.dispose();
      index.comment.dispose();
      for (final part in index.parts) {
        part.prefix.dispose();
      }
    }
    for (final fk in _foreignKeys) {
      fk.name.dispose();
      fk.referencedSchema.dispose();
      fk.referencedTable.dispose();
      for (final pair in fk.pairs) {
        pair.referenced.dispose();
      }
    }
    super.dispose();
  }

  String? _optional(String text) => text.isEmpty ? null : text;

  /// 界面状态拼成草稿。前缀长度填的不是数字就直接报错，不当成没填
  TableDraft _buildDraft() {
    final indexes = <IndexDraft>[];
    for (final index in _indexes) {
      final parts = <IndexPart>[];
      for (final part in index.parts) {
        final prefixText = part.prefix.text.trim();
        final prefix = prefixText.isEmpty ? null : int.tryParse(prefixText);
        if (prefixText.isNotEmpty && (prefix == null || prefix < 0)) {
          throw FormatException('索引 ${index.name.text} 的前缀长度「$prefixText」不是数字');
        }
        parts.add(IndexPart(column: part.column?.name.text, prefix: prefix, descending: part.descending));
      }
      indexes.add(IndexDraft(
        originalName: index.originalName,
        name: index.kind == IndexKind.primary ? 'PRIMARY' : index.name.text,
        kind: index.kind,
        parts: parts,
        comment: index.comment.text,
        locked: index.locked,
      ));
    }

    final autoIncrementText = _autoIncrement.text.trim();
    final autoIncrement = autoIncrementText.isEmpty ? null : BigInt.tryParse(autoIncrementText);
    if (autoIncrementText.isNotEmpty && (autoIncrement == null || autoIncrement.isNegative)) {
      throw FormatException('AUTO_INCREMENT「$autoIncrementText」不是正整数');
    }

    return TableDraft(
      columns: [
        for (final column in _columns)
          ColumnDraft(
            originalName: column.originalName,
            name: column.name.text,
            columnType: column.type.text,
            nullable: column.nullable,
            default_: column.defaultValue,
            autoIncrement: column.autoIncrement,
            onUpdate: _optional(column.onUpdate.text),
            comment: column.comment.text,
            collation: _optional(column.collation.text),
            locked: column.locked,
          ),
      ],
      indexes: indexes,
      foreignKeys: [
        for (final fk in _foreignKeys)
          ForeignKeyDraft(
            originalName: fk.originalName,
            name: fk.name.text,
            columns: [for (final pair in fk.pairs) pair.column.name.text],
            referencedSchema: fk.referencedSchema.text,
            referencedTable: fk.referencedTable.text,
            referencedColumns: [for (final pair in fk.pairs) pair.referenced.text],
            onUpdate: fk.onUpdate,
            onDelete: fk.onDelete,
          ),
      ],
      checks: [
        for (final check in _checks)
          CheckDraft(
            originalName: check.originalName,
            name: check.name.text,
            expression: check.expression.text,
            enforced: check.enforced,
          ),
      ],
      options: TableOptionsDraft(
        engine: _engine.text.trim(),
        charset: _optional(_charset.text.trim()),
        collation: _optional(_collation.text.trim()),
        comment: _tableComment.text,
        autoIncrement: autoIncrement,
        rowFormat: _optional(_rowFormat.text.trim()),
        convertCharset: _convertCharset,
      ),
    );
  }

  Future<void> _preview() async {
    final TableDraft draft;
    try {
      draft = _buildDraft();
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }

    // 新建表的表名原样交给 core，不在界面上修剪：修剪过的名字和用户看到的不是同一个
    final table = widget.table ?? _tableName.text;
    final structure = widget.structure;
    setState(() {
      _error = null;
      _previewing = true;
    });
    AlterPlan plan;
    try {
      plan = structure == null
          ? await widget.source.previewCreateTable(widget.database, table, draft)
          : await widget.source.previewAlter(widget.database, table, structure, draft);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _previewing = false;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _previewing = false);

    final applied = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PreviewDialog(
        plan: plan,
        apply: () => structure == null
            ? widget.source.createTable(widget.database, table, draft, plan.statements)
            : widget.source.applyAlter(widget.database, table, structure, draft, plan.statements),
      ),
    );
    if (applied == true && mounted) Navigator.of(context).pop(table);
  }

  void _addColumn() {
    setState(() {
      _columns.add(_ColumnRow(const ColumnDraft(
        name: '',
        columnType: 'varchar(255)',
        nullable: true,
        default_: DefaultValue.null_(),
        autoIncrement: false,
        comment: '',
      )));
    });
  }

  /// 删列时把索引、外键里引用它的地方一起拿掉；拿空了的索引留给 core 报错，不偷偷删索引
  void _removeColumn(_ColumnRow column) {
    setState(() {
      _columns.remove(column);
      _removedColumns.add(column);
      for (final index in _indexes) {
        index.parts.removeWhere((part) => part.column == column);
      }
      for (final fk in _foreignKeys) {
        fk.pairs.removeWhere((pair) => pair.column == column);
      }
    });
  }

  void _moveColumn(int from, int to) {
    if (to < 0 || to >= _columns.length) return;
    setState(() => _columns.insert(to, _columns.removeAt(from)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    final error = _error;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 1100,
        height: 640,
        child: DefaultTabController(
          length: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: _creating
                    ? Row(
                        children: [
                          Text('新建表：${widget.database}.', style: titleStyle),
                          SizedBox(width: 260, child: _field(_tableName, hint: '表名', key: const ValueKey('table-name'))),
                        ],
                      )
                    : Text('编辑结构：${widget.database}.${widget.table}', style: titleStyle),
              ),
              MacPanelBar(
                children: [
                  Expanded(
                    child: MacTabBar(
                      labels: [
                        '列 ${_columns.length}',
                        '索引 ${_indexes.length}',
                        '外键 ${_foreignKeys.length}',
                        'CHECK ${_checks.length}',
                        '表选项',
                      ],
                    ),
                  ),
                ],
              ),
              Expanded(
                child: ColoredBox(
                  color: scheme.surface,
                  child: TabBarView(
                    children: [_columnsTab(), _indexesTab(), _foreignKeysTab(), _checksTab(), _optionsTab()],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SelectableText(error, style: TextStyle(color: scheme.error, fontSize: 12)),
                      ),
                    Row(
                      children: [
                        Text('改动在预览确认之前不会写入数据库', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                        const Spacer(),
                        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _previewing ? null : _preview,
                          child: Text(_previewing ? '生成中…' : '预览 DDL'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 表格下面一条：放「添加…」按钮
  Widget _addBar(Widget button) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: button,
    );
  }

  // ---- 列 ----

  // 操作按钮放第一列：表比对话框宽，放最后要横着滚才看得到删除
  static const _columnWidths = [96.0, 150.0, 160.0, 40.0, 110.0, 150.0, 40.0, 170.0, 150.0, 180.0];

  Widget _columnsTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _Table(
            widths: _columnWidths,
            headers: const ['', '列名', '类型', '可空', '默认值', '', '自增', 'ON UPDATE', '排序规则', '注释'],
            rows: [for (var i = 0; i < _columns.length; i++) _columnRow(i)],
          ),
        ),
        _addBar(TextButton.icon(
          key: const ValueKey('add-column'),
          onPressed: _addColumn,
          icon: const Icon(Icons.add, size: 14),
          label: const Text('添加列'),
        )),
      ],
    );
  }

  List<Widget> _columnRow(int i) {
    final column = _columns[i];
    final editable = column.locked == null;
    final hasDefaultText = column.defaultKind == _DefaultKind.literal || column.defaultKind == _DefaultKind.expression;
    return [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            child: editable
                ? null
                : Tooltip(
                    message: column.locked!,
                    child: Icon(
                      Icons.lock_outline,
                      key: ValueKey('column-locked-$i'),
                      size: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
          _iconButton(Icons.arrow_upward, '上移', () => _moveColumn(i, i - 1)),
          _iconButton(Icons.arrow_downward, '下移', () => _moveColumn(i, i + 1)),
          _iconButton(Icons.delete_outline, '删除列', () => _removeColumn(column), key: ValueKey('column-delete-$i')),
        ],
      ),
      _field(column.name, key: ValueKey('column-name-$i')),
      _field(column.type, enabled: editable, key: ValueKey('column-type-$i')),
      _checkbox(
        column.nullable,
        editable ? (value) => setState(() => column.nullable = value) : null,
        key: ValueKey('column-nullable-$i'),
      ),
      MacPopupButton<_DefaultKind>(
        key: ValueKey('column-default-kind-$i'),
        value: column.defaultKind,
        expand: true,
        onChanged: editable ? (value) => setState(() => column.defaultKind = value) : null,
        items: {for (final kind in _DefaultKind.values) kind: _defaultKindLabels[kind]!},
      ),
      _field(column.defaultText, enabled: editable && hasDefaultText, key: ValueKey('column-default-$i')),
      _checkbox(
        column.autoIncrement,
        editable ? (value) => setState(() => column.autoIncrement = value) : null,
      ),
      // 空着就是没有 ON UPDATE。提示写成例子的话，一排空框看起来像每列都设了 CURRENT_TIMESTAMP
      _field(column.onUpdate, enabled: editable, hint: '无'),
      _field(column.collation, enabled: editable, hint: '表默认'),
      _field(column.comment, enabled: editable, key: ValueKey('column-comment-$i')),
    ];
  }

  // ---- 索引 ----

  Widget _indexesTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [for (var i = 0; i < _indexes.length; i++) _indexBlock(i)],
          ),
        ),
        _addBar(TextButton.icon(
          onPressed: () => setState(() {
            _indexes.add(_IndexRow(
              originalName: null,
              locked: null,
              name: '',
              comment: '',
              kind: IndexKind.normal,
              parts: [_PartRow(_columns.isEmpty ? null : _columns.first)],
            ));
          }),
          icon: const Icon(Icons.add, size: 14),
          label: const Text('添加索引'),
        )),
      ],
    );
  }

  Widget _indexBlock(int i) {
    final index = _indexes[i];
    final editable = index.locked == null;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: _groupBox(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 110,
                child: MacPopupButton<IndexKind>(
                  value: index.kind,
                  expand: true,
                  onChanged: editable ? (value) => setState(() => index.kind = value) : null,
                  items: {for (final kind in IndexKind.values) kind: _indexKindLabels[kind]!},
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 200,
                child: _field(index.name, enabled: index.kind != IndexKind.primary, hint: '索引名', key: ValueKey('index-name-$i')),
              ),
              const SizedBox(width: 8),
              SizedBox(width: 240, child: _field(index.comment, enabled: editable, hint: '注释')),
              if (!editable) ...[
                const SizedBox(width: 8),
                Tooltip(message: index.locked!, child: Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant)),
              ],
              const Spacer(),
              _iconButton(Icons.delete_outline, '删除索引', () => setState(() => _indexes.removeAt(i)), key: ValueKey('index-delete-$i')),
            ],
          ),
          for (var p = 0; p < index.parts.length; p++) _partRow(index, p, editable),
          if (editable)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: TextButton.icon(
                onPressed: _columns.isEmpty ? null : () => setState(() => index.parts.add(_PartRow(_columns.first))),
                icon: const Icon(Icons.add, size: 14),
                label: const Text('添加列', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _partRow(_IndexRow index, int p, bool editable) {
    final part = index.parts[p];
    final column = part.column;
    return Padding(
      padding: const EdgeInsets.only(left: 20, top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: column == null
                ? _label('<表达式>')
                : _columnPicker(column, editable ? (picked) => setState(() => part.column = picked) : null),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 90, child: _field(part.prefix, enabled: editable, hint: '前缀长度')),
          const SizedBox(width: 8),
          _checkbox(part.descending, editable ? (value) => setState(() => part.descending = value) : null),
          const SizedBox(width: 4),
          _label('降序'),
          const SizedBox(width: 8),
          if (editable) ...[
            _iconButton(Icons.arrow_upward, '上移', () {
              if (p == 0) return;
              setState(() => index.parts.insert(p - 1, index.parts.removeAt(p)));
            }),
            _iconButton(Icons.close, '移除这一列', () => setState(() => index.parts.removeAt(p))),
          ],
        ],
      ),
    );
  }

  // ---- 外键 ----

  Widget _foreignKeysTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [for (var i = 0; i < _foreignKeys.length; i++) _foreignKeyBlock(i)],
          ),
        ),
        _addBar(TextButton.icon(
          onPressed: _columns.isEmpty
              ? null
              : () => setState(() {
                    _foreignKeys.add(_ForeignKeyRow(
                      originalName: null,
                      name: '',
                      referencedSchema: widget.database,
                      referencedTable: '',
                      pairs: [_ForeignKeyPair(_columns.first, '')],
                      onUpdate: 'RESTRICT',
                      onDelete: 'RESTRICT',
                    ));
                  }),
          icon: const Icon(Icons.add, size: 14),
          label: const Text('添加外键'),
        )),
      ],
    );
  }

  Widget _foreignKeyBlock(int i) {
    final fk = _foreignKeys[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: _groupBox(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(width: 180, child: _field(fk.name, hint: '外键名', key: ValueKey('fk-name-$i'))),
              const SizedBox(width: 8),
              _label('引用'),
              const SizedBox(width: 4),
              SizedBox(width: 130, child: _field(fk.referencedSchema, hint: '库')),
              _label(' . '),
              SizedBox(width: 160, child: _field(fk.referencedTable, hint: '表', key: ValueKey('fk-table-$i'))),
              const SizedBox(width: 12),
              _label('ON DELETE'),
              const SizedBox(width: 4),
              _actionPicker(fk.onDelete, (value) => setState(() => fk.onDelete = value)),
              const SizedBox(width: 12),
              _label('ON UPDATE'),
              const SizedBox(width: 4),
              _actionPicker(fk.onUpdate, (value) => setState(() => fk.onUpdate = value)),
              const Spacer(),
              _iconButton(Icons.delete_outline, '删除外键', () => setState(() => _foreignKeys.removeAt(i)), key: ValueKey('fk-delete-$i')),
            ],
          ),
          for (var p = 0; p < fk.pairs.length; p++)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 4),
              child: Row(
                children: [
                  SizedBox(width: 200, child: _columnPicker(fk.pairs[p].column, (picked) => setState(() => fk.pairs[p].column = picked))),
                  _label('  →  '),
                  SizedBox(width: 200, child: _field(fk.pairs[p].referenced, hint: '引用的列', key: ValueKey('fk-ref-$i-$p'))),
                  _iconButton(Icons.close, '移除这一列', () => setState(() => fk.pairs.removeAt(p))),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 2),
            child: TextButton.icon(
              onPressed: _columns.isEmpty ? null : () => setState(() => fk.pairs.add(_ForeignKeyPair(_columns.first, ''))),
              icon: const Icon(Icons.add, size: 14),
              label: const Text('添加列', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  // ---- CHECK ----

  Widget _checksTab() {
    final scheme = Theme.of(context).colorScheme;
    // 改表时 checks 是 null：服务器读不了 CHECK，加了 core 也会拒绝，这里直接说明
    final unsupported = !_creating && widget.structure!.checks == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (unsupported)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Text(
              '这个服务器读不到 CHECK 约束（要 MySQL 8.0.16+）。更早的版本会解析 CHECK 但不执行，所以这里不能加。',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            '已有的 CHECK 约束只能删除，要改就删掉再新加一条。表达式里不能有括号外的逗号、分号、注释。',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: _Table(
            widths: const [40, 200, 520, 80],
            headers: const ['', '约束名', '表达式', '强制执行'],
            rows: [for (var i = 0; i < _checks.length; i++) _checkRow(i)],
          ),
        ),
        _addBar(TextButton.icon(
          key: const ValueKey('add-check'),
          onPressed: unsupported
              ? null
              : () => setState(() {
                    _checks.add(_CheckRow(const CheckDraft(name: '', expression: '', enforced: true)));
                  }),
          icon: const Icon(Icons.add, size: 14),
          label: const Text('添加 CHECK'),
        )),
      ],
    );
  }

  List<Widget> _checkRow(int i) {
    final check = _checks[i];
    final editable = check.originalName == null;
    return [
      _iconButton(Icons.delete_outline, '删除 CHECK', () {
        setState(() {
          _checks.removeAt(i);
          _removedChecks.add(check);
        });
      }, key: ValueKey('check-delete-$i')),
      _field(check.name, enabled: editable, hint: '留空自动起名', key: ValueKey('check-name-$i')),
      _field(check.expression, enabled: editable, hint: 'price >= 0', key: ValueKey('check-expression-$i')),
      _checkbox(
        check.enforced,
        editable ? (value) => setState(() => check.enforced = value) : null,
        key: ValueKey('check-enforced-$i'),
      ),
    ];
  }

  // ---- 表选项 ----

  Widget _optionsTab() {
    final scheme = Theme.of(context).colorScheme;
    final current = widget.structure?.autoIncrement;
    final autoIncrementHint = _creating ? '留空从 1 开始' : (current == null ? '留空不改' : '当前 $current，留空不改');
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      children: [
        _optionRow('引擎', _field(_engine, key: const ValueKey('option-engine'))),
        _optionRow('默认字符集', _field(_charset, hint: _creating ? '跟库的默认' : null, key: const ValueKey('option-charset'))),
        _optionRow('排序规则', _field(_collation, hint: _creating ? '字符集的默认' : null, key: const ValueKey('option-collation'))),
        if (!_creating)
          Padding(
            padding: const EdgeInsets.only(left: _optionLabelWidth + 8, top: 2, bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 480,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _checkbox(
                      _convertCharset,
                      (value) => setState(() => _convertCharset = value),
                      key: const ValueKey('option-convert'),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '转换已有列（CONVERT TO CHARACTER SET）。不勾只改表的默认值，已有的列不动、之后新加的列才用它；'
                        '勾上会把所有字符串列的数据转换过去，重写整张表。',
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        _optionRow('表注释', _field(_tableComment, key: const ValueKey('option-comment'))),
        _optionRow('AUTO_INCREMENT', _field(_autoIncrement, hint: autoIncrementHint, key: const ValueKey('option-auto-increment'))),
        _optionRow('ROW_FORMAT', _field(_rowFormat, hint: '引擎默认', key: const ValueKey('option-row-format'))),
      ],
    );
  }

  static const double _optionLabelWidth = 140;

  Widget _optionRow(String label, Widget field) {
    return FormRow(
      label: label,
      labelWidth: _optionLabelWidth,
      child: Align(alignment: Alignment.centerLeft, child: SizedBox(width: 360, child: field)),
    );
  }

  /// 索引、外键一条一个框：内容区上的浅灰分组框，像 NSBox
  BoxDecoration _groupBox() {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: scheme.surfaceContainerLow,
      border: Border.all(color: scheme.outlineVariant),
      borderRadius: BorderRadius.circular(6),
    );
  }

  Widget _actionPicker(String value, ValueChanged<String> onChanged) {
    return MacPopupButton<String>(
      value: value,
      onChanged: onChanged,
      items: {for (final action in _foreignKeyActions) action: action},
    );
  }

  /// 列的下拉框。选项是当前的列（显示当前名字），值是列对象
  Widget _columnPicker(_ColumnRow value, ValueChanged<_ColumnRow>? onChanged) {
    return MacPopupButton<_ColumnRow?>(
      value: _columns.contains(value) ? value : null,
      expand: true,
      onChanged: onChanged == null
          ? null
          : (picked) {
              if (picked != null) onChanged(picked);
            },
      placeholder: '（选一列）',
      items: {for (final column in _columns) column: column.name.text.isEmpty ? '（未命名）' : column.name.text},
    );
  }

  /// 表格里的输入框：细边框、紧凑，一行 24px
  Widget _field(TextEditingController controller, {bool enabled = true, String? hint, Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      key: key,
      controller: controller,
      enabled: enabled,
      // 列名改了，索引和外键下拉框里的名字要跟着刷新
      onChanged: (_) => setState(() {}),
      style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
      decoration: InputDecoration(
        hintText: hint,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        // 不能改的格子不填白底，一眼看出哪些是锁住的
        fillColor: enabled ? null : Colors.transparent,
      ),
    );
  }

  Widget _checkbox(bool value, ValueChanged<bool>? onChanged, {Key? key}) {
    return Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: Checkbox(
          key: key,
          value: value,
          onChanged: onChanged == null ? null : (checked) => onChanged(checked ?? false),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(text, style: const TextStyle(fontSize: 12));

  Widget _iconButton(IconData icon, String tooltip, VoidCallback onPressed, {Key? key}) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      iconSize: 14,
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      style: IconButton.styleFrom(minimumSize: const Size(24, 24), padding: EdgeInsets.zero),
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

/// 固定列宽的表格，横竖都能滚
class _Table extends StatelessWidget {
  final List<double> widths;
  final List<String> headers;
  final List<List<Widget>> rows;

  const _Table({required this.widths, required this.headers, required this.rows});

  @override
  Widget build(BuildContext context) {
    var totalWidth = 0.0;
    for (final width in widths) {
      totalWidth += width;
    }
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          // 比对话框窄时撑满，表头和隔行底色一直画到右边
          width: totalWidth > constraints.maxWidth ? totalWidth : constraints.maxWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 22,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
                ),
                child: _cells([
                  for (final header in headers)
                    Text(
                      header,
                      maxLines: 1,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
                    ),
                ], divider: scheme.outlineVariant),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < rows.length; i++)
                      Container(
                        color: i.isOdd ? scheme.surfaceContainerLow : scheme.surface,
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: _cells(rows[i]),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cells(List<Widget> cells, {Color? divider}) {
    return Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          Container(
            width: widths[i],
            padding: const EdgeInsets.symmetric(horizontal: 3),
            alignment: Alignment.centerLeft,
            decoration: divider == null ? null : BoxDecoration(border: Border(right: BorderSide(color: divider))),
            child: cells[i],
          ),
      ],
    );
  }
}

/// DDL 预览：危险操作醒目标出，执行须知写清楚，确认后才执行
class _PreviewDialog extends StatefulWidget {
  final AlterPlan plan;
  final Future<void> Function() apply;

  const _PreviewDialog({required this.plan, required this.apply});

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  bool _running = false;
  String? _error;

  Future<void> _apply() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await widget.apply();
    } catch (e) {
      if (mounted) {
        setState(() {
          _running = false;
          _error = '$e';
        });
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = widget.plan;
    final error = _error;
    final dangerous = plan.dangers.isNotEmpty;
    return Dialog(
      child: SizedBox(
        width: 860,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('确认要执行的 DDL', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    if (dangerous)
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(5)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '以下操作可能丢数据或丢约束',
                              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: scheme.onErrorContainer),
                            ),
                            for (final danger in plan.dangers)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(Icons.warning_amber, size: 16, color: scheme.onErrorContainer),
                                    const SizedBox(width: 6),
                                    Expanded(child: Text(danger, style: TextStyle(fontSize: 12, color: scheme.onErrorContainer))),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    for (final note in plan.notes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('· $note', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < plan.statements.length; i++)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          border: Border.all(color: scheme.outlineVariant),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (plan.statements.length > 1)
                              Text('第 ${i + 1} 条', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                            SelectableText(
                              plan.statements[i],
                              style: const TextStyle(fontSize: 12, fontFamily: 'Menlo', height: 1.5),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableText('执行失败：$error', style: TextStyle(color: scheme.error, fontSize: 12)),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: _running ? null : () => Navigator.of(context).pop(false),
                    child: const Text('返回修改'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: dangerous ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError) : null,
                    onPressed: _running ? null : _apply,
                    child: Text(_running ? '执行中…' : (dangerous ? '我已了解风险，执行' : '执行')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
