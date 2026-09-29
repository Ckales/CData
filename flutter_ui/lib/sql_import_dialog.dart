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
        database: widget.database,
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
    final failure = summary?.failure;
    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.file_upload_outlined, color: colors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('导入 SQL'),
                  const SizedBox(height: 2),
                  Text(
                    '按文件顺序执行脚本中的语句',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.62,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _section(
                    icon: Icons.description_outlined,
                    title: 'SQL 文件',
                    child: Row(
                      children: [
                        Expanded(
                          child: _path == null
                              ? Text(
                                  '尚未选择文件',
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                  ),
                                )
                              : SelectableText(
                                  _path!,
                                  semanticsLabel: 'SQL 文件路径：$_path',
                                ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: _running || summary != null ? null : _pick,
                          icon: const Icon(
                            Icons.folder_open_outlined,
                            size: 16,
                          ),
                          label: const Text('选择文件'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _section(
                    icon: Icons.storage_outlined,
                    title: '目标数据库',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.database.isEmpty ? '未选择数据库' : widget.database,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (widget.database.isEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '脚本需要自行创建或选择数据库。',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _section(
                    icon: Icons.translate_outlined,
                    title: '文件编码',
                    child: DropdownButton<ExportEncoding>(
                      value: _encoding,
                      isExpanded: true,
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
                  ),
                  const SizedBox(height: 10),
                  _messageCard(
                    icon: Icons.info_outline,
                    title: '执行说明',
                    message: '遇到错误即停止。此前已执行的写入和 DDL 可能无法撤回。',
                    background: colors.tertiaryContainer,
                    foreground: colors.onTertiaryContainer,
                  ),
                  if (_running) ...[
                    const SizedBox(height: 10),
                    _section(
                      icon: Icons.sync,
                      title: '正在执行',
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(),
                          SizedBox(height: 6),
                          Text('正在执行，请等待结果…'),
                        ],
                      ),
                    ),
                  ],
                  if (summary != null) ...[
                    const SizedBox(height: 10),
                    _section(
                      icon: failure == null
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      title: failure == null ? '导入完成' : '执行结果',
                      child: Row(
                        children: [
                          Expanded(
                            child: _resultMetric(
                              '已执行语句',
                              summary.executed.toString(),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _resultMetric(
                              '影响行数',
                              summary.affectedRows.toString(),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (failure != null) ...[
                      const SizedBox(height: 10),
                      _messageCard(
                        icon: Icons.error_outline,
                        title: '数据库返回错误',
                        message:
                            '第 ${failure.statement} 条语句 · 文件第 ${failure.line} 行\n${failure.message}\n\n后续语句未执行。',
                        background: colors.errorContainer,
                        foreground: colors.onErrorContainer,
                      ),
                    ],
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    _messageCard(
                      icon: Icons.error_outline,
                      title: '无法执行导入',
                      message: _error!,
                      background: colors.errorContainer,
                      foreground: colors.onErrorContainer,
                    ),
                  ],
                ],
              ),
            ),
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

  Widget _section({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colors.primary),
              const SizedBox(width: 7),
              Semantics(header: true, child: Text(title)),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _messageCard({
    required IconData icon,
    required String title,
    required String message,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 7),
              Semantics(header: true, child: Text(title)),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(message, style: TextStyle(color: foreground)),
        ],
      ),
    );
  }

  Widget _resultMetric(String label, String value) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: colors.onSurfaceVariant)),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
