import 'package:file_selector/file_selector.dart' show XTypeGroup, openFile;
import 'package:flutter/material.dart';

import 'src/rust/api/db.dart' show ExportEncoding;
import 'src/rust/api/editor.dart' show SqlImportSummary, importSqlFile;

/// 返回是否开始过执行，调用方据此刷新库表与当前结果。
Future<bool> showSqlImportDialog(
  BuildContext context, {
  required BigInt sessionId,
  required String database,
  String? initialPath,
  Future<String?> Function()? pickFile,
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _SqlImportDialog(
          sessionId: sessionId,
          database: database,
          initialPath: initialPath,
          pickFile: pickFile ?? _pickSqlFile,
        ),
      ) ??
      false;
}

Future<String?> _pickSqlFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'SQL', extensions: ['sql']),
    ],
  );
  return file?.path;
}

class _SqlImportDialog extends StatefulWidget {
  final BigInt sessionId;
  final String database;
  final String? initialPath;
  final Future<String?> Function() pickFile;

  const _SqlImportDialog({
    required this.sessionId,
    required this.database,
    this.initialPath,
    required this.pickFile,
  });

  @override
  State<_SqlImportDialog> createState() => _SqlImportDialogState();
}

class _SqlImportDialogState extends State<_SqlImportDialog> {
  String? _path;
  ExportEncoding _encoding = ExportEncoding.utf8;
  SqlImportSummary? _summary;
  String? _error;
  bool _running = false;
  bool _attempted = false;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
  }

  Future<void> _pick() async {
    try {
      final path = await widget.pickFile();
      if (path != null && mounted) setState(() => _path = path);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _run() async {
    final path = _path;
    if (path == null || _running) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final summary = await importSqlFile(
        sessionId: widget.sessionId,
        path: path,
        encoding: _encoding,
      );
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _attempted = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final summary = _summary;
    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        title: const Text('导入 SQL'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.database.isEmpty
                    ? '当前未选数据库；脚本需要自行创建或选择数据库。'
                    : '当前数据库：${widget.database}',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _path ?? '还没选文件',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _running || summary != null ? null : _pick,
                    child: const Text('选择文件…'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              DropdownButton<ExportEncoding>(
                value: _encoding,
                onChanged: _running || summary != null
                    ? null
                    : (value) => setState(() => _encoding = value!),
                items: const [
                  DropdownMenuItem(
                    value: ExportEncoding.utf8,
                    child: Text('UTF-8（含 BOM）'),
                  ),
                  DropdownMenuItem(
                    value: ExportEncoding.gbk,
                    child: Text('GBK'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('按文件中的顺序执行 SQL；遇到错误即停止。此前已执行的写入和 DDL 可能无法撤回。'),
              if (_running) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('正在执行，请等待结果…'),
              ],
              if (summary != null) ...[
                const SizedBox(height: 16),
                Text(
                  '已执行 ${summary.executed} 条语句，共影响 ${summary.affectedRows} 行。',
                ),
                if (summary.failure case final failure?) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    '第 ${failure.statement} 条语句（文件第 ${failure.line} 行）失败，后续未执行：\n${failure.message}',
                    style: TextStyle(color: colors.error),
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                SelectableText(_error!, style: TextStyle(color: colors.error)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _running
                ? null
                : () => Navigator.of(context).pop(_attempted),
            child: Text(summary == null ? '取消' : '关闭'),
          ),
          if (summary == null)
            FilledButton(
              onPressed: _path == null || _running ? null : _run,
              child: const Text('执行导入'),
            ),
        ],
      ),
    );
  }
}
