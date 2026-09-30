import 'package:file_selector/file_selector.dart' show XTypeGroup, openFile;
import 'package:flutter/material.dart';

import 'mac_widgets.dart';
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
    final screen = MediaQuery.sizeOf(context);
    final width = (screen.width - 56).clamp(0.0, 580.0).toDouble();
    final maxHeight = (screen.height - 56).clamp(0.0, 520.0).toDouble();
    return PopScope(
      canPop: !_running,
      child: Dialog(
        insetPadding: const EdgeInsets.all(28),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(colors),
                Divider(height: 1, color: colors.outlineVariant),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _sqlRow(
                          'SQL 文件',
                          Row(
                            children: [
                              Expanded(child: _fileValue(colors)),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                key: const ValueKey('sql-import-pick-file'),
                                onPressed: _running || summary != null
                                    ? null
                                    : _pick,
                                child: const Text('选择文件…'),
                              ),
                            ],
                          ),
                        ),
                        _sqlRow(
                          '目标数据库',
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _valueBox(
                                colors,
                                Text(
                                  widget.database.isEmpty
                                      ? '未选择数据库'
                                      : widget.database,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: widget.database.isEmpty
                                        ? colors.onSurfaceVariant
                                        : colors.onSurface,
                                  ),
                                ),
                              ),
                              if (widget.database.isEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '脚本需要自行创建或选择数据库。',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        _sqlRow(
                          '文件编码',
                          MacPopupButton<ExportEncoding>(
                            key: const ValueKey('sql-import-encoding'),
                            value: _encoding,
                            expand: true,
                            items: const {
                              ExportEncoding.utf8: 'UTF-8（含 BOM）',
                              ExportEncoding.gbk: 'GBK',
                            },
                            onChanged: _running || summary != null
                                ? null
                                : (value) => setState(() => _encoding = value),
                          ),
                        ),
                        _messageCard(
                          icon: Icons.warning_amber_rounded,
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
                Divider(height: 1, color: colors.outlineVariant),
                _footer(colors),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ColorScheme colors) {
    return SizedBox(
      height: 58,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                Icons.file_upload_outlined,
                size: 17,
                color: colors.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '导入 SQL',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '按文件顺序执行脚本中的语句',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileValue(ColorScheme colors) {
    final path = _path;
    final value = path == null ? '尚未选择文件' : path.split(RegExp(r'[/\\]')).last;
    return Tooltip(
      message: path ?? '',
      child: _valueBox(
        colors,
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          semanticsLabel: path == null ? value : 'SQL 文件路径：$path',
          style: TextStyle(
            color: path == null ? colors.onSurfaceVariant : colors.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _valueBox(ColorScheme colors, Widget child) {
    return Container(
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(5),
      ),
      child: child,
    );
  }

  Widget _sqlRow(String label, Widget child) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 102,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _footer(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '支持 .sql 文件 · 编码可选 UTF-8 或 GBK',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: _running
                ? null
                : () => Navigator.of(context).pop(_attempted),
            child: Text(_summary == null ? '取消' : '关闭'),
          ),
          if (_summary == null) ...[
            const SizedBox(width: 6),
            FilledButton(
              onPressed: _path == null || _running ? null : _run,
              child: const Text('执行导入'),
            ),
          ],
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
      padding: const EdgeInsets.all(10),
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
          const SizedBox(height: 6),
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
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
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
          SelectableText(
            message,
            style: TextStyle(fontSize: 12, color: foreground),
          ),
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
