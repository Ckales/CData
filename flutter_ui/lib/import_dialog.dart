import 'package:file_selector/file_selector.dart' show XTypeGroup, getSaveLocation, openFile;
import 'package:flutter/material.dart';

import 'data_source.dart';
import 'src/rust/api/csv_import.dart';
import 'src/rust/api/db.dart' show ExportEncoding;
import 'src/rust/api/value.dart' show DisplayCell;

Future<String?> _systemOpenPath() async {
  final file = await openFile(acceptedTypeGroups: const [
    XTypeGroup(label: 'CSV', extensions: ['csv', 'tsv', 'txt']),
  ]);
  return file?.path;
}

Future<String?> _systemSavePath(String suggestedName) async {
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: const [XTypeGroup(label: 'CSV', extensions: ['csv'])],
  );
  return location?.path;
}

/// 预览多少行
const int _previewRows = 50;

/// 每条 INSERT 带几行
const int _batchRows = 500;

/// 进度多久刷新一次
const Duration _pollEvery = Duration(milliseconds: 300);

/// 把 CSV 导入到已有的表。三步：选文件与格式 → 预览与列映射 → 执行结果。
///
/// 返回有没有行真正提交进了表里，调用方据此决定要不要重新查询。
Future<bool> showImportDialog(
  BuildContext context, {
  required ImportSource source,
  required String database,
  required String table,
  Future<String?> Function()? pickFile,
  Future<String?> Function(String suggestedName)? pickSavePath,
}) async {
  final committed = await showDialog<bool>(
    context: context,
    // 导入跑到一半点到外面就关掉，用户会以为取消了，其实还在写
    barrierDismissible: false,
    builder: (context) => _ImportDialog(
      source: source,
      database: database,
      table: table,
      pickFile: pickFile ?? _systemOpenPath,
      pickSavePath: pickSavePath ?? _systemSavePath,
    ),
  );
  return committed ?? false;
}

enum _Step { file, mapping, result }

class _ImportDialog extends StatefulWidget {
  final ImportSource source;
  final String database;
  final String table;
  final Future<String?> Function() pickFile;
  final Future<String?> Function(String suggestedName) pickSavePath;

  const _ImportDialog({
    required this.source,
    required this.database,
    required this.table,
    required this.pickFile,
    required this.pickSavePath,
  });

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  _Step _step = _Step.file;

  ImportTarget? _target;
  String? _targetError;

  String? _path;
  ExportEncoding _encoding = ExportEncoding.utf8;
  String _delimiter = ',';
  bool _header = true;
  // 和导出的默认值一致，同样的选项导出再导回来才一模一样
  String _nullText = 'NULL';

  bool _loading = false;
  CsvPreview? _preview;
  String? _previewError;
  List<int?> _mapping = [];
  OnError _onError = OnError.rollbackAll;
  String? _startError;

  int? _job;
  ImportStatus? _status;
  String? _pollError;
  bool _cancelling = false;
  String? _saveMessage;

  @override
  void initState() {
    super.initState();
    _loadTarget();
  }

  @override
  void dispose() {
    final job = _job;
    // 删的是错误行临时文件，失败了也只是临时目录里多一个文件，不值得拦住关闭
    if (job != null) widget.source.close(job).ignore();
    super.dispose();
  }

  Future<void> _loadTarget() async {
    try {
      final target = await widget.source.target(widget.database, widget.table);
      if (!mounted) return;
      setState(() => _target = target);
    } catch (err) {
      if (!mounted) return;
      setState(() => _targetError = err.toString());
    }
  }

  ImportOptions get _options => ImportOptions(
        encoding: _encoding,
        delimiter: _delimiter,
        header: _header,
        nullText: _nullText,
      );

  Future<void> _pickFile() async {
    final path = await widget.pickFile();
    if (path == null || !mounted) return;
    setState(() {
      _path = path;
      _previewError = null;
    });
  }

  Future<void> _loadPreview() async {
    final path = _path;
    final target = _target;
    if (path == null || target == null) return;

    setState(() {
      _loading = true;
      _previewError = null;
    });
    try {
      final preview = await widget.source.preview(path, _options, _previewRows);
      if (!mounted) return;
      final columnCount = preview.columnCount.toInt();
      if (columnCount == 0) {
        setState(() {
          _loading = false;
          _previewError = '文件是空的';
        });
        return;
      }
      setState(() {
        _loading = false;
        _preview = preview;
        // 只有表头能给出建议；没有表头不按位置猜，由用户逐列选
        _mapping = _header
            ? widget.source.suggestMapping(preview.header, target.columns)
            : List<int?>.filled(columnCount, null);
        _startError = null;
        _step = _Step.mapping;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _previewError = err.toString();
      });
    }
  }

  Future<void> _start() async {
    final path = _path;
    if (path == null) return;
    final request = ImportRequest(
      path: path,
      options: _options,
      schema: widget.database,
      table: widget.table,
      mapping: _mapping,
      batchRows: _batchRows,
      onError: _onError,
    );
    setState(() {
      _loading = true;
      _startError = null;
    });
    try {
      final job = await widget.source.start(request);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _job = job;
        _step = _Step.result;
      });
      await _poll(job);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _startError = err.toString();
      });
    }
  }

  Future<void> _poll(int job) async {
    while (mounted) {
      final ImportStatus status;
      try {
        status = await widget.source.status(job);
      } catch (err) {
        if (!mounted) return;
        setState(() => _pollError = err.toString());
        return;
      }
      if (!mounted) return;
      setState(() => _status = status);
      if (status is ImportStatus_Finished) return;
      await Future<void>.delayed(_pollEvery);
    }
  }

  Future<void> _cancel() async {
    final job = _job;
    if (job == null) return;
    setState(() => _cancelling = true);
    await widget.source.cancel(job);
  }

  Future<void> _saveErrors() async {
    final job = _job;
    if (job == null) return;
    final path = await widget.pickSavePath('${widget.table}_errors.csv');
    if (path == null || !mounted) return;
    try {
      final rows = await widget.source.saveErrors(job, path);
      if (!mounted) return;
      setState(() => _saveMessage = '已把 $rows 行失败的数据导出到 $path');
    } catch (err) {
      if (!mounted) return;
      setState(() => _saveMessage = '导出错误行失败：$err');
    }
  }

  /// 已经开始、还没结束。这时候不能关对话框，只能取消
  bool get _running => _job != null && _status is! ImportStatus_Finished && _pollError == null;

  @override
  Widget build(BuildContext context) {
    return PopScope(canPop: !_running, child: _dialog());
  }

  Widget _dialog() {
    return AlertDialog(
      title: Text('导入到 ${widget.database}.${widget.table}', style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: _step == _Step.file ? 460 : 760,
        child: switch (_step) {
          _Step.file => _fileStep(),
          _Step.mapping => _mappingStep(),
          _Step.result => _resultStep(),
        },
      ),
      actions: switch (_step) {
        _Step.file => [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
            FilledButton(
              key: const ValueKey('import-next'),
              onPressed: _path != null && _target != null && !_loading ? _loadPreview : null,
              child: Text(_loading ? '读取中…' : '下一步'),
            ),
          ],
        _Step.mapping => [
            TextButton(
              onPressed: _loading ? null : () => setState(() => _step = _Step.file),
              child: const Text('上一步'),
            ),
            FilledButton(
              key: const ValueKey('import-start'),
              onPressed: _loading ? null : _start,
              child: Text(_loading ? '检查中…' : '开始导入'),
            ),
          ],
        _Step.result => _resultActions(),
      },
    );
  }

  Widget _fileStep() {
    final colors = Theme.of(context).colorScheme;
    final targetError = _targetError;
    final previewError = _previewError;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (targetError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('不能导入：$targetError', style: TextStyle(fontSize: 12, color: colors.error)),
          ),
        _row(
          '文件',
          Row(
            children: [
              Expanded(
                child: Text(
                  _path ?? '还没选文件',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: _path == null ? colors.onSurfaceVariant : colors.onSurface),
                ),
              ),
              TextButton(key: const ValueKey('import-pick-file'), onPressed: _pickFile, child: const Text('选择…')),
            ],
          ),
        ),
        _row(
          '编码',
          _dropdown<ExportEncoding>(
            'import-encoding',
            _encoding,
            const {
              ExportEncoding.utf8: 'UTF-8',
              ExportEncoding.utf8Bom: 'UTF-8（带 BOM）',
              ExportEncoding.gbk: 'GBK',
            },
            (value) => _encoding = value,
          ),
        ),
        _row(
          '分隔符',
          _dropdown<String>(
            'import-delimiter',
            _delimiter,
            const {',': '逗号 ,', ';': '分号 ;', '\t': '制表符'},
            (value) => _delimiter = value,
          ),
        ),
        _row(
          'NULL 写法',
          _dropdown<String>(
            'import-null',
            _nullText,
            const {'NULL': 'NULL', '': '空（空字符串写成 ""）', r'\N': r'\N'},
            (value) => _nullText = value,
          ),
        ),
        _row(
          '首行是列名',
          Checkbox(
            key: const ValueKey('import-header'),
            value: _header,
            onChanged: (value) => setState(() => _header = value ?? true),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '编码不会自动识别，选错了会报出哪一行解不了。没加引号的 NULL 写法是 NULL，加了引号的是文本。'
          '用导出时的同一组选项，数据才能原样导回来。',
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        ),
        if (previewError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(previewError, style: TextStyle(fontSize: 12, color: colors.error)),
          ),
      ],
    );
  }

  Widget _mappingStep() {
    final colors = Theme.of(context).colorScheme;
    final preview = _preview!;
    final target = _target!;
    final previewError = preview.error;
    final startError = _startError;

    final mapped = <int>{};
    for (final index in _mapping) {
      if (index != null) mapped.add(index);
    }
    final missing = <String>[];
    for (var i = 0; i < target.columns.length; i++) {
      if (target.columns[i].mandatory && !mapped.contains(i)) missing.add(target.columns[i].name);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!target.strict)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '当前会话的 sql_mode 不是 strict（${target.sqlMode.isEmpty ? '空' : target.sqlMode}），'
              'MySQL 会把放不下的值静默截断或转换。本次导入只在导入用的连接上临时加 STRICT_ALL_TABLES，'
              '这类值会报错而不是被改掉；你的查询会话不受影响。',
              key: const ValueKey('import-sql-mode'),
              style: TextStyle(fontSize: 12, color: colors.error),
            ),
          ),
        Text(
          '前 ${preview.rows.length} 行。每一列选一个目标列，或者跳过；没映射的表列交给默认值 / 自增。',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Flexible(child: _previewTable(preview, target)),
        if (previewError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('$previewError。导入会在这里停下', style: TextStyle(fontSize: 12, color: colors.error)),
          ),
        if (missing.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${missing.join('、')} 不允许 NULL 也没有默认值，必须映射一列',
              style: TextStyle(fontSize: 12, color: colors.error),
            ),
          ),
        const SizedBox(height: 6),
        _row(
          '出错时',
          _dropdown<OnError>(
            'import-on-error',
            _onError,
            const {
              OnError.rollbackAll: '整体回滚：有一行失败就全部不写入（仍会检查完所有行）',
              OnError.skipRow: '跳过错误行继续：每批单独提交',
            },
            (value) => _onError = value,
          ),
        ),
        if (startError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(startError, style: TextStyle(fontSize: 12, color: colors.error)),
          ),
      ],
    );
  }

  static const double _lineWidth = 56;
  static const double _cellWidth = 160;

  Widget _previewTable(CsvPreview preview, ImportTarget target) {
    final colors = Theme.of(context).colorScheme;
    final columnCount = preview.columnCount.toInt();
    final cellStyle = TextStyle(fontSize: 12, fontFamily: 'Menlo', color: colors.onSurface);
    final placeholderStyle = cellStyle.copyWith(color: colors.onSurfaceVariant, fontStyle: FontStyle.italic);

    Widget cell(DisplayCell? value) {
      if (value == null) return const SizedBox(width: _cellWidth);
      return SizedBox(
        width: _cellWidth,
        child: Text(
          value.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: value.placeholder ? placeholderStyle : cellStyle,
        ),
      );
    }

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: _lineWidth, child: Text('行', style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant))),
        for (var i = 0; i < columnCount; i++)
          SizedBox(
            width: _cellWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i < preview.header.length ? preview.header[i] : '第 ${i + 1} 列',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                _mappingDropdown(i, target),
              ],
            ),
          ),
      ],
    );

    final rows = <Widget>[];
    for (final row in preview.rows) {
      final error = row.error;
      rows.add(Row(
        children: [
          SizedBox(
            width: _lineWidth,
            child: Text('${row.line}', style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
          ),
          for (var i = 0; i < columnCount; i++) cell(i < row.cells.length ? row.cells[i] : null),
          if (error != null) Text(error, style: TextStyle(fontSize: 12, color: colors.error)),
        ],
      ));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        // 列多时横向滚动；多出来的宽度留给行尾的列数错误
        width: _lineWidth + columnCount * _cellWidth + 200,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            const Divider(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mappingDropdown(int csvIndex, ImportTarget target) {
    final colors = Theme.of(context).colorScheme;
    final items = <DropdownMenuItem<int?>>[
      DropdownMenuItem<int?>(value: null, child: Text('跳过', style: TextStyle(color: colors.onSurfaceVariant))),
    ];
    for (var i = 0; i < target.columns.length; i++) {
      final column = target.columns[i];
      final label = column.generated
          ? '${column.name}（生成列）'
          : column.mandatory
              ? '${column.name}（必填）'
              : column.name;
      items.add(DropdownMenuItem<int?>(
        value: i,
        enabled: !column.generated,
        child: Text(label, overflow: TextOverflow.ellipsis),
      ));
    }
    return DropdownButton<int?>(
      key: ValueKey('import-map-$csvIndex'),
      value: _mapping[csvIndex],
      isDense: true,
      isExpanded: true,
      style: TextStyle(fontSize: 12, color: colors.onSurface),
      items: items,
      onChanged: (value) => setState(() => _mapping[csvIndex] = value),
    );
  }

  Widget _resultStep() {
    final colors = Theme.of(context).colorScheme;
    final pollError = _pollError;
    if (pollError != null) {
      return Text('读不到导入进度：$pollError', style: TextStyle(fontSize: 12, color: colors.error));
    }
    final status = _status;
    if (status == null) return const Text('开始导入…', style: TextStyle(fontSize: 12));

    switch (status) {
      case ImportStatus_Running(field0: final progress):
        final total = progress.totalBytes.toDouble();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_cancelling ? '正在取消…' : '正在导入…', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            // 有确定进度的进度条不会无限重绘
            LinearProgressIndicator(value: total == 0 ? 0 : progress.bytesRead.toDouble() / total),
            const SizedBox(height: 8),
            Text(
              '已读 ${progress.rowsRead} 行 · 已写入 ${progress.rowsInserted} 行'
              '${_onError == OnError.rollbackAll ? '（全部完成后才提交）' : ''} · 失败 ${progress.rowsFailed} 行',
              key: const ValueKey('import-progress'),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        );
      case ImportStatus_Finished(field0: final report):
        return _reportView(report);
    }
  }

  Widget _reportView(ImportReport report) {
    final colors = Theme.of(context).colorScheme;
    final progress = report.progress;
    final failed = progress.rowsFailed.toInt();
    final (headline, isError) = switch (report.outcome) {
      ImportOutcome_Completed() when failed == 0 => ('导入完成，写入 ${progress.rowsInserted} 行', false),
      ImportOutcome_Completed() => ('导入完成，写入 ${progress.rowsInserted} 行，跳过 $failed 行', true),
      ImportOutcome_RolledBack() => ('有 $failed 行失败，已整体回滚，没有写入任何行', true),
      ImportOutcome_Stopped(field0: final reason) => ('导入中途停止：$reason', true),
    };
    final saveMessage = _saveMessage;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          headline,
          key: const ValueKey('import-headline'),
          style: TextStyle(fontSize: 13, color: isError ? colors.error : colors.onSurface),
        ),
        const SizedBox(height: 6),
        Text(
          '读取 ${progress.rowsRead} 行 · 写入 ${progress.rowsInserted} 行 · 失败 $failed 行',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
        if (report.errors.isNotEmpty) ...[
          const SizedBox(height: 8),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final error in report.errors)
                    Text('第 ${error.line} 行：${error.reason}', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
          if (report.errors.length < failed)
            Text(
              '只列出前 ${report.errors.length} 条，全部 $failed 行可以导出成 CSV',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
        ],
        if (saveMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(saveMessage, style: const TextStyle(fontSize: 12)),
          ),
      ],
    );
  }

  List<Widget> _resultActions() {
    final status = _status;
    if (_pollError != null) {
      // 不知道写进去多少，让调用方按「可能有」处理，重新查一次
      return [FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('关闭'))];
    }
    if (status is! ImportStatus_Finished) {
      return [
        TextButton(
          key: const ValueKey('import-cancel'),
          onPressed: _cancelling || _job == null ? null : _cancel,
          child: const Text('取消导入'),
        ),
      ];
    }
    final report = status.field0;
    return [
      if (report.progress.rowsFailed > BigInt.zero)
        TextButton(key: const ValueKey('import-save-errors'), onPressed: _saveErrors, child: const Text('导出错误行…')),
      FilledButton(
        key: const ValueKey('import-done'),
        onPressed: () => Navigator.of(context).pop(report.progress.rowsInserted > BigInt.zero),
        child: const Text('完成'),
      ),
    ];
  }

  Widget _row(String label, Widget field) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: field)),
        ],
      ),
    );
  }

  Widget _dropdown<T>(String key, T value, Map<T, String> items, void Function(T value) onChanged) {
    return DropdownButton<T>(
      key: ValueKey(key),
      value: value,
      isDense: true,
      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
      items: [
        for (final entry in items.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      onChanged: (selected) {
        if (selected != null) setState(() => onChanged(selected));
      },
    );
  }
}
