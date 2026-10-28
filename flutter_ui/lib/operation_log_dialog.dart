import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'mac_widgets.dart';
import 'src/rust/api/operation_log.dart' as operation_log;
import 'src/rust/api/value.dart';

/// 打开只读 SQL 操作日志。
Future<void> showOperationLogDialog(
  BuildContext context, {
  Future<List<OperationLogEntry>> Function()? load,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _OperationLogDialog(load: load ?? operation_log.listOperationLogs),
  );
}

enum _LogStatus { all, succeeded, failed }

class _OperationLogDialog extends StatefulWidget {
  final Future<List<OperationLogEntry>> Function() load;

  const _OperationLogDialog({required this.load});

  @override
  State<_OperationLogDialog> createState() => _OperationLogDialogState();
}

class _OperationLogDialogState extends State<_OperationLogDialog> {
  final _search = TextEditingController();
  List<OperationLogEntry>? _entries;
  String? _error;
  _LogStatus _status = _LogStatus.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _entries = null;
      _error = null;
    });
    try {
      final entries = await widget.load();
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = math.max(0.0, math.min(960.0, size.width - 48));
    final height = math.max(0.0, math.min(720.0, size.height - 48));
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MacPanelBar(
              children: [
                Text(
                  'SQL 操作日志',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 28,
                      child: TextField(
                        key: const ValueKey('operation-log-search'),
                        controller: _search,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search, size: 15),
                          prefixIconConstraints: BoxConstraints(
                            minWidth: 28,
                            minHeight: 24,
                          ),
                          contentPadding: EdgeInsets.symmetric(vertical: 5),
                          hintText: '搜索 SQL 或消息',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  MacPopupButton<_LogStatus>(
                    key: const ValueKey('operation-log-status-filter'),
                    value: _status,
                    items: const {
                      _LogStatus.all: '全部状态',
                      _LogStatus.succeeded: '仅成功',
                      _LogStatus.failed: '仅失败',
                    },
                    onChanged: (value) => setState(() => _status = value),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                '保留最近 10,000 条，超出后覆盖最旧记录；不按天数清理。本地保存，重启后仍可查看。SQL 参数和敏感内容已隐藏，从此版本开始记录。',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText('读取 SQL 操作日志失败：$error'),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final entries = _entries;
    if (entries == null) return const Center(child: Text('加载中…'));
    if (entries.isEmpty) return _empty('暂无 SQL 操作日志');

    final keyword = _search.text.trim().toLowerCase();
    final matched = entries
        .where((entry) {
          final statusMatches = switch (_status) {
            _LogStatus.all => true,
            _LogStatus.succeeded => entry.succeeded,
            _LogStatus.failed => !entry.succeeded,
          };
          final searchMatches =
              keyword.isEmpty ||
              entry.detail.toLowerCase().contains(keyword) ||
              entry.message.toLowerCase().contains(keyword);
          return statusMatches && searchMatches;
        })
        .toList(growable: false);
    if (matched.isEmpty) return _empty('没有匹配的日志');

    return ListView.separated(
      itemCount: matched.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => _entryTile(matched[index]),
    );
  }

  Widget _empty(String text) => Center(
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  Widget _entryTile(OperationLogEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final stateColor = entry.succeeded ? scheme.primary : scheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _formatTime(entry.executedAt),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              Text(
                switch (entry.operation) {
                  'query' => '查询',
                  'update' => '更新',
                  'insert' => '插入',
                  'delete' => '删除',
                  'paste' => '批量粘贴',
                  'script' => 'SQL 脚本',
                  'import' => 'SQL 导入',
                  'explain' => '执行计划',
                  'ddl' || 'alter' || 'create_table' || 'table_action' || 'create_database' => '结构变更',
                  'kill_process' => '终止进程',
                  'set_global' => '设置变量',
                  'user_change' => '用户管理',
                  _ => entry.operation,
                },
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                entry.succeeded ? '成功' : '失败',
                style: TextStyle(fontSize: 11, color: stateColor),
              ),
              Text(
                '耗时 ${entry.elapsedMs} ms',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 5),
          SelectableText(
            entry.detail,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          if (entry.message.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              entry.message,
              style: TextStyle(
                fontSize: 11,
                color: entry.succeeded ? scheme.onSurfaceVariant : scheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTime(int milliseconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }
}
