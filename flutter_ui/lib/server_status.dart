import 'dart:async';

import 'package:flutter/material.dart';

import 'server_source.dart';
import 'src/rust/api/server.dart';
import 'src/rust/api/value.dart' show DisplayCell;

/// 服务器状态：进程、变量、状态计数、慢日志四页。
///
/// KILL 和 SET GLOBAL 都要二次确认：页面上的按钮只打开确认框，确认框里说清后果再执行。
/// 拦截规则（自己的连接、目标变了、语句和预览不一致）在 core 里，这里不重复判断。
Future<void> showServerStatus(
  BuildContext context, {
  required ServerSource source,
  required String serverLabel,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ServerStatusDialog(source: source, serverLabel: serverLabel),
  );
}

/// 自动刷新的间隔（秒），0 是不自动刷新
const List<int> _refreshChoices = [0, 2, 5, 10, 30];

const TextStyle _mono = TextStyle(fontSize: 12, fontFamily: 'Menlo');

class _ServerStatusDialog extends StatelessWidget {
  final ServerSource source;
  final String serverLabel;

  const _ServerStatusDialog({required this.source, required this.serverLabel});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 1100,
        height: 720,
        child: DefaultTabController(
          length: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('服务器状态 · $serverLabel', style: Theme.of(context).textTheme.titleMedium),
                    ),
                    IconButton(
                      key: const ValueKey('server-close'),
                      tooltip: '关闭',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [Tab(text: '进程'), Tab(text: '变量'), Tab(text: '状态'), Tab(text: '慢日志')],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _ProcessesPage(source: source),
                    _VariablesPage(source: source),
                    _StatusPage(source: source),
                    _SlowLogPage(source: source),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// NULL、二进制、解码失败画成斜体灰字，和内容恰好是这些字的文本区分开
Widget _cell(BuildContext context, DisplayCell cell, {double? width, int? maxLines = 1, bool selectable = false}) {
  final scheme = Theme.of(context).colorScheme;
  final style = cell.placeholder
      ? _mono.copyWith(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic)
      : _mono.copyWith(color: scheme.onSurface);
  final Widget text = selectable
      ? SelectableText(cell.text, style: style, maxLines: maxLines)
      : Text(cell.text, style: style, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
  if (width == null) return text;
  return SizedBox(width: width, child: text);
}

enum _BannerKind { info, warning, error }

class _Banner extends StatelessWidget {
  final String text;
  final _BannerKind kind;

  const _Banner(this.text, {this.kind = _BannerKind.info});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 警告沿用截断提示的琥珀色：这套 seed 的 tertiaryContainer 是粉色，和 errorContainer 分不开
    final (background, foreground) = switch (kind) {
      _BannerKind.info => (scheme.surfaceContainerHighest, scheme.onSurface),
      _BannerKind.warning => (Color.alphaBlend(Colors.amber.withValues(alpha: 0.3), scheme.surface), scheme.onSurface),
      _BannerKind.error => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SelectableText(text, style: TextStyle(fontSize: 12, color: foreground)),
    );
  }
}

const String _truncatedText = '行数超过上限，只显示了前面一部分。';

class _RefreshPicker extends StatelessWidget {
  final String keyPrefix;
  final int seconds;
  final ValueChanged<int> onChanged;

  const _RefreshPicker({required this.keyPrefix, required this.seconds, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButton<int>(
      key: ValueKey('$keyPrefix-auto'),
      value: seconds,
      isDense: true,
      items: [
        for (final choice in _refreshChoices)
          DropdownMenuItem(value: choice, child: Text(choice == 0 ? '不自动刷新' : '每 $choice 秒刷新')),
      ],
      onChanged: (choice) => onChanged(choice!),
    );
  }
}

/// 自动刷新：上一轮还没回来就跳过这一拍，不叠请求
mixin _Polling<T extends StatefulWidget> on State<T> {
  Timer? _timer;
  int intervalSeconds = 0;
  bool loading = false;

  Future<void> refresh();

  void setInterval(int seconds) {
    _timer?.cancel();
    _timer = null;
    setState(() => intervalSeconds = seconds);
    if (seconds == 0) return;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!loading) refresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ---------------- 进程 ----------------

class _ProcessesPage extends StatefulWidget {
  final ServerSource source;

  const _ProcessesPage({required this.source});

  @override
  State<_ProcessesPage> createState() => _ProcessesPageState();
}

class _ProcessesPageState extends State<_ProcessesPage> with _Polling {
  ProcessList? _list;
  String? _error;
  String? _message;
  String? _killError;
  BigInt? _selectedId;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  Future<void> refresh() async {
    setState(() => loading = true);
    try {
      final list = await widget.source.processes();
      if (!mounted) return;
      setState(() {
        _list = list;
        _error = null;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  ProcessInfo? get _selected {
    final list = _list;
    if (list == null || _selectedId == null) return null;
    for (final process in list.processes) {
      if (process.id == _selectedId) return process;
    }
    return null;
  }

  Future<void> _kill(ProcessInfo target, KillMode mode) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _KillConfirmDialog(target: target, mode: mode),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.source.kill(target, mode);
      if (!mounted) return;
      final what = mode == KillMode.query ? 'KILL QUERY' : 'KILL CONNECTION';
      setState(() {
        _message = '已对线程 ${target.id} 执行 $what';
        _killError = null;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _message = null;
        _killError = 'KILL 没有执行：$err';
      });
    }
    await refresh();
  }

  static const double _idWidth = 90;
  static const double _userWidth = 100;
  static const double _hostWidth = 150;
  static const double _dbWidth = 100;
  static const double _commandWidth = 80;
  static const double _timeWidth = 60;
  static const double _stateWidth = 150;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = _list;
    final selected = _selected;
    final header = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              OutlinedButton.icon(
                key: const ValueKey('processes-refresh'),
                onPressed: loading ? null : refresh,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(loading ? '加载中…' : '刷新'),
              ),
              const SizedBox(width: 12),
              _RefreshPicker(keyPrefix: 'processes', seconds: intervalSeconds, onChanged: setInterval),
              const Spacer(),
              if (list != null) Text('${list.processes.length} 个线程', style: header),
            ],
          ),
        ),
        if (list?.notice != null) _Banner(list!.notice!, kind: _BannerKind.warning),
        if (list?.truncated == true) const _Banner(_truncatedText, kind: _BannerKind.warning),
        if (_error != null) _Banner('读不到进程列表：$_error', kind: _BannerKind.error),
        if (_message != null) _Banner(_message!),
        if (_killError != null) _Banner(_killError!, kind: _BannerKind.error),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              SizedBox(width: _idWidth, child: Text('Id', style: header)),
              SizedBox(width: _userWidth, child: Text('用户', style: header)),
              SizedBox(width: _hostWidth, child: Text('主机', style: header)),
              SizedBox(width: _dbWidth, child: Text('库', style: header)),
              SizedBox(width: _commandWidth, child: Text('命令', style: header)),
              SizedBox(width: _timeWidth, child: Text('秒', style: header)),
              SizedBox(width: _stateWidth, child: Text('状态', style: header)),
              Expanded(child: Text('语句', style: header)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: list == null
              ? const SizedBox.shrink()
              : ListView.builder(
                  itemCount: list.processes.length,
                  itemBuilder: (context, index) {
                    final process = list.processes[index];
                    final isSelected = process.id == _selectedId;
                    return InkWell(
                      key: ValueKey('process-${process.id}'),
                      onTap: () => setState(() => _selectedId = process.id),
                      child: Container(
                        color: isSelected ? scheme.primaryContainer : null,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: _idWidth,
                              child: Row(
                                children: [
                                  Text('${process.id}', style: _mono),
                                  if (process.isOwn) ...[
                                    const SizedBox(width: 4),
                                    _OwnBadge(key: ValueKey('process-own-${process.id}')),
                                  ],
                                ],
                              ),
                            ),
                            _cell(context, process.user, width: _userWidth),
                            _cell(context, process.host, width: _hostWidth),
                            _cell(context, process.db, width: _dbWidth),
                            _cell(context, process.command, width: _commandWidth),
                            _cell(context, process.time, width: _timeWidth),
                            _cell(context, process.state, width: _stateWidth),
                            Expanded(child: _cell(context, process.info)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        _ProcessDetail(
          selectedId: _selectedId,
          process: selected,
          onKill: _kill,
        ),
      ],
    );
  }
}

class _OwnBadge extends StatelessWidget {
  const _OwnBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'CData 自己正在用的连接',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(color: scheme.tertiary, borderRadius: BorderRadius.circular(3)),
        child: Text('CData', style: TextStyle(fontSize: 10, color: scheme.onTertiary)),
      ),
    );
  }
}

/// 选中线程的完整语句和 KILL 按钮
class _ProcessDetail extends StatelessWidget {
  final BigInt? selectedId;
  final ProcessInfo? process;
  final Future<void> Function(ProcessInfo target, KillMode mode) onKill;

  const _ProcessDetail({required this.selectedId, required this.process, required this.onKill});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final process = this.process;
    final hint = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    if (process == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          selectedId == null ? '点一行查看完整语句，或者 KILL 它' : '线程 $selectedId 已经不在列表里了（可能已经结束）',
          style: hint,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('线程 ${process.id} 的完整语句', style: hint),
          const SizedBox(height: 4),
          Container(
            key: const ValueKey('process-detail-sql'),
            constraints: const BoxConstraints(maxHeight: 120),
            padding: const EdgeInsets.all(8),
            color: scheme.surfaceContainerHighest,
            child: SingleChildScrollView(child: _cell(context, process.info, maxLines: null, selectable: true)),
          ),
          const SizedBox(height: 8),
          if (process.isOwn)
            const _Banner(
              '这是 CData 自己正在用的连接（本工具的查询或连接池里的连接），不能在这里 KILL：会打断本工具自己的查询',
              kind: _BannerKind.error,
            )
          else
            Row(
              children: [
                OutlinedButton(
                  key: const ValueKey('process-kill-query'),
                  onPressed: () => onKill(process, KillMode.query),
                  child: const Text('终止语句（KILL QUERY）…'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const ValueKey('process-kill-connection'),
                  style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                  onPressed: () => onKill(process, KillMode.connection),
                  child: const Text('断开连接（KILL CONNECTION）…'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _KillConfirmDialog extends StatelessWidget {
  final ProcessInfo target;
  final KillMode mode;

  const _KillConfirmDialog({required this.target, required this.mode});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isQuery = mode == KillMode.query;
    final label = isQuery ? 'KILL QUERY' : 'KILL CONNECTION';
    final body = TextStyle(fontSize: 13, color: scheme.onSurface);

    Widget line(String name, DisplayCell value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 56, child: Text(name, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
            Expanded(child: _cell(context, value)),
          ],
        ),
      );
    }

    return AlertDialog(
      title: Text(isQuery ? '终止线程 ${target.id} 正在执行的语句？' : '断开线程 ${target.id} 的整条连接？'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              line('用户', target.user),
              line('主机', target.host),
              line('库', target.db),
              line('命令', target.command),
              line('状态', target.state),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 140),
                padding: const EdgeInsets.all(8),
                color: scheme.surfaceContainerHighest,
                child: SingleChildScrollView(child: _cell(context, target.info, maxLines: null, selectable: true)),
              ),
              const SizedBox(height: 12),
              Text('两种 KILL 的区别：', style: body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '· KILL QUERY：只停掉这条连接正在执行的那条语句，连接保留。被打断的语句自己的改动回滚，'
                '但事务不结束，之前语句的改动还在、锁也还在，对方程序会收到「查询被中断」。',
                style: body.copyWith(fontWeight: isQuery ? FontWeight.w600 : null),
              ),
              const SizedBox(height: 4),
              Text(
                '· KILL CONNECTION：断开整条连接。正在执行的语句停止，没提交的事务全部回滚，'
                '会话变量和临时表丢失，对方程序要重新连接。',
                style: body.copyWith(fontWeight: isQuery ? null : FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '大的写操作被打断后要回滚已经改过的行，可能要很久（状态显示 Killed）。'
                '列表是刷新时的快照，执行前会再核对一次：这条线程已经结束，或者（KILL QUERY 时）已经换了语句，就不执行。',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('kill-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('kill-confirm'),
          style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('确认 $label'),
        ),
      ],
    );
  }
}

// ---------------- 变量 ----------------

class _VariablesPage extends StatefulWidget {
  final ServerSource source;

  const _VariablesPage({required this.source});

  @override
  State<_VariablesPage> createState() => _VariablesPageState();
}

class _VariablesPageState extends State<_VariablesPage> {
  VariableScope _scope = VariableScope.global;
  VariableList? _list;
  String? _error;
  String _search = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final scope = _scope;
    setState(() => _loading = true);
    try {
      final list = await widget.source.variables(scope);
      if (!mounted || scope != _scope) return;
      setState(() {
        _list = list;
        _error = null;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit(Variable variable) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _SetGlobalDialog(
        source: widget.source,
        name: variable.name,
        initialValue: variable.value.placeholder ? '' : variable.value.text,
        fixedValue: false,
      ),
    );
    if (changed == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = _list;
    final needle = _search.toLowerCase();
    final visible = <Variable>[];
    if (list != null) {
      for (final variable in list.variables) {
        if (variable.name.toLowerCase().contains(needle)) visible.add(variable);
      }
    }
    final isGlobal = _scope == VariableScope.global;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              SegmentedButton<VariableScope>(
                key: const ValueKey('variables-scope'),
                segments: const [
                  ButtonSegment(value: VariableScope.global, label: Text('全局 GLOBAL')),
                  ButtonSegment(value: VariableScope.session, label: Text('会话 SESSION')),
                ],
                selected: {_scope},
                onSelectionChanged: (selection) {
                  setState(() {
                    _scope = selection.first;
                    _list = null;
                  });
                  _load();
                },
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 260,
                child: TextField(
                  key: const ValueKey('variables-search'),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 16),
                    hintText: '按名字搜索',
                  ),
                  onChanged: (text) => setState(() => _search = text),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                key: const ValueKey('variables-refresh'),
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(_loading ? '加载中…' : '刷新'),
              ),
              const Spacer(),
              if (list != null)
                Text('${visible.length} / ${list.variables.length}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        if (isGlobal)
          const _Banner('点右侧的笔可以改全局值（SET GLOBAL），会先预览语句、说明影响，再确认执行。')
        else
          const _Banner(
            '会话值来自 CData 连接池里的一条连接：连接每次归还都会重置成全局值，再执行 SET NAMES utf8mb4。'
            '所以这一页只读 —— 在这里 SET SESSION 不会作用到查询标签。'
            '要改会话变量，在查询里把 SET SESSION 和要跑的语句一起写成多语句脚本，它们在同一条连接上按顺序执行。',
            kind: _BannerKind.warning,
          ),
        if (list?.truncated == true) const _Banner(_truncatedText, kind: _BannerKind.warning),
        if (_error != null) _Banner('读不到变量：$_error', kind: _BannerKind.error),
        Expanded(
          child: ListView.builder(
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final variable = visible[index];
              return Padding(
                key: ValueKey('variable-${variable.name}'),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: Row(
                  children: [
                    SizedBox(width: 320, child: SelectableText(variable.name, style: _mono, maxLines: 1)),
                    Expanded(child: _cell(context, variable.value, maxLines: 2, selectable: true)),
                    if (isGlobal)
                      IconButton(
                        key: ValueKey('variable-edit-${variable.name}'),
                        tooltip: '修改全局值…',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit),
                        onPressed: () => _edit(variable),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 改全局变量：填值 → core 预览语句和影响 → 确认执行 → 显示服务器存下的值。
///
/// fixedValue 为 true 时值由调用方定（开关慢日志），直接从预览开始
class _SetGlobalDialog extends StatefulWidget {
  final ServerSource source;
  final String name;
  final String initialValue;
  final bool fixedValue;

  const _SetGlobalDialog({
    required this.source,
    required this.name,
    required this.initialValue,
    required this.fixedValue,
  });

  @override
  State<_SetGlobalDialog> createState() => _SetGlobalDialogState();
}

class _SetGlobalDialogState extends State<_SetGlobalDialog> {
  late final TextEditingController _value = TextEditingController(text: widget.initialValue);
  SetVariablePlan? _plan;
  String? _planValue;
  DisplayCell? _applied;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.fixedValue) _preview();
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    final value = _value.text;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plan = await widget.source.previewSetGlobal(widget.name, value);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _planValue = value;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final plan = _plan!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final applied = await widget.source.applySetGlobal(widget.name, _planValue!, plan.statement);
      if (!mounted) return;
      setState(() => _applied = applied);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = _plan;
    final applied = _applied;
    final hint = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);

    final children = <Widget>[];
    if (plan == null) {
      children.add(TextField(
        key: const ValueKey('set-global-value'),
        controller: _value,
        style: _mono,
        decoration: const InputDecoration(labelText: '新的全局值'),
        onChanged: (_) => setState(() {}),
      ));
      children.add(const SizedBox(height: 8));
      children.add(Text('纯数字按数值发送，其余（ON / OFF、枚举值、路径）按字符串发送，转义由 core 负责。', style: hint));
    } else {
      children.add(Text('将要执行：', style: hint));
      children.add(Container(
        margin: const EdgeInsets.only(top: 4, bottom: 8),
        padding: const EdgeInsets.all(8),
        color: scheme.surfaceContainerHighest,
        child: SelectableText(plan.statement, key: const ValueKey('set-global-statement'), style: _mono),
      ));
      children.add(Row(children: [Text('现在的值：', style: hint), Expanded(child: _cell(context, plan.currentValue))]));
      children.add(const SizedBox(height: 8));
      children.add(Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(4)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final warning in plan.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· $warning', style: TextStyle(fontSize: 12, color: scheme.onErrorContainer)),
              ),
          ],
        ),
      ));
    }
    if (applied != null) {
      children.add(const SizedBox(height: 8));
      children.add(Row(
        key: const ValueKey('set-global-applied'),
        children: [Text('已生效，服务器上现在的值：', style: hint), Expanded(child: _cell(context, applied))],
      ));
    }
    if (_error != null) {
      children.add(const SizedBox(height: 8));
      children.add(SelectableText(_error!, style: TextStyle(fontSize: 12, color: scheme.error)));
    }

    final actions = <Widget>[];
    if (applied != null) {
      actions.add(FilledButton(
        key: const ValueKey('set-global-done'),
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('完成'),
      ));
    } else {
      actions.add(TextButton(
        key: const ValueKey('set-global-cancel'),
        onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        child: const Text('取消'),
      ));
      if (plan == null) {
        actions.add(FilledButton(
          key: const ValueKey('set-global-preview'),
          onPressed: _busy || widget.fixedValue ? null : _preview,
          child: Text(_busy ? '预览中…' : '预览'),
        ));
      } else {
        actions.add(FilledButton(
          key: const ValueKey('set-global-apply'),
          style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: _busy ? null : _apply,
          child: Text(_busy ? '执行中…' : '我已了解影响，执行 SET GLOBAL'),
        ));
      }
    }

    return AlertDialog(
      title: Text('修改全局变量 ${widget.name}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
      actions: actions,
    );
  }
}

// ---------------- 状态 ----------------

class _StatusPage extends StatefulWidget {
  final ServerSource source;

  const _StatusPage({required this.source});

  @override
  State<_StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<_StatusPage> with _Polling {
  StatusSnapshot? _snapshot;
  String? _error;
  String _search = '';

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  Future<void> refresh() async {
    setState(() => loading = true);
    try {
      final snapshot = await widget.source.status(_snapshot);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snapshot = _snapshot;
    final needle = _search.toLowerCase();
    final visible = <StatusCounter>[];
    if (snapshot != null) {
      for (final counter in snapshot.counters) {
        if (counter.name.toLowerCase().contains(needle)) visible.add(counter);
      }
    }
    final header = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              OutlinedButton.icon(
                key: const ValueKey('status-refresh'),
                onPressed: loading ? null : refresh,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(loading ? '加载中…' : '刷新'),
              ),
              const SizedBox(width: 12),
              _RefreshPicker(keyPrefix: 'status', seconds: intervalSeconds, onChanged: setInterval),
              const SizedBox(width: 12),
              SizedBox(
                width: 260,
                child: TextField(
                  key: const ValueKey('status-search'),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 16),
                    hintText: '按名字搜索，比如 Threads',
                  ),
                  onChanged: (text) => setState(() => _search = text),
                ),
              ),
            ],
          ),
        ),
        const _Banner('SHOW GLOBAL STATUS。差值和每秒是和上一次刷新比的，第一次刷新没有；瞬时值（Threads_running 这类）只给差值。'),
        if (snapshot?.truncated == true) const _Banner(_truncatedText, kind: _BannerKind.warning),
        if (_error != null) _Banner('读不到状态：$_error', kind: _BannerKind.error),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              SizedBox(width: 360, child: Text('名字', style: header)),
              Expanded(child: Text('值', style: header)),
              SizedBox(width: 140, child: Text('差值', style: header)),
              SizedBox(width: 140, child: Text('每秒', style: header)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final counter = visible[index];
              return Padding(
                key: ValueKey('status-${counter.name}'),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: Row(
                  children: [
                    SizedBox(width: 360, child: Text(counter.name, style: _mono)),
                    Expanded(child: _cell(context, counter.value)),
                    SizedBox(width: 140, child: Text(counter.delta ?? '', style: _mono)),
                    SizedBox(width: 140, child: Text(counter.rate ?? '', style: _mono)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------- 慢日志 ----------------

const List<int> _slowLogLimits = [20, 50, 100, 500];

class _SlowLogPage extends StatefulWidget {
  final ServerSource source;

  const _SlowLogPage({required this.source});

  @override
  State<_SlowLogPage> createState() => _SlowLogPageState();
}

class _SlowLogPageState extends State<_SlowLogPage> {
  SlowLogConfig? _config;
  List<SlowLogEntry>? _entries;
  String? _error;
  int _limit = _slowLogLimits.first;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final config = await widget.source.slowLogConfig();
      List<SlowLogEntry>? entries;
      if (config.tableUnavailable == null) entries = await widget.source.slowLogEntries(_limit);
      if (!mounted) return;
      setState(() {
        _config = config;
        _entries = entries;
        _error = null;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(SlowLogConfig config) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _SetGlobalDialog(
        source: widget.source,
        name: 'slow_query_log',
        initialValue: config.enabled ? 'OFF' : 'ON',
        fixedValue: true,
      ),
    );
    if (changed == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final config = _config;
    final entries = _entries;
    final hint = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);

    Widget setting(String name, DisplayCell value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          children: [
            SizedBox(width: 160, child: Text(name, style: _mono.copyWith(color: scheme.onSurfaceVariant))),
            Expanded(child: _cell(context, value, selectable: true)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              OutlinedButton.icon(
                key: const ValueKey('slow-refresh'),
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(_loading ? '加载中…' : '刷新'),
              ),
              const SizedBox(width: 12),
              if (config != null)
                OutlinedButton(
                  key: const ValueKey('slow-toggle'),
                  onPressed: () => _toggle(config),
                  child: Text(config.enabled ? '关闭慢日志…' : '开启慢日志…'),
                ),
              const SizedBox(width: 12),
              if (config != null && config.tableUnavailable == null) ...[
                Text('最近', style: hint),
                const SizedBox(width: 6),
                DropdownButton<int>(
                  key: const ValueKey('slow-limit'),
                  value: _limit,
                  isDense: true,
                  items: [for (final limit in _slowLogLimits) DropdownMenuItem(value: limit, child: Text('$limit 条'))],
                  onChanged: (limit) {
                    setState(() => _limit = limit!);
                    _load();
                  },
                ),
              ],
            ],
          ),
        ),
        if (_error != null) _Banner('读不到慢日志：$_error', kind: _BannerKind.error),
        if (config != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                setting('slow_query_log', config.slowQueryLog),
                setting('log_output', config.logOutput),
                setting('long_query_time', config.longQueryTime),
                setting('slow_query_log_file', config.slowQueryLogFile),
                const SizedBox(height: 4),
                Text('log_output、long_query_time 在「变量」页里改。', style: hint),
              ],
            ),
          ),
        if (config?.tableUnavailable != null) _Banner(config!.tableUnavailable!, kind: _BannerKind.warning),
        if (config != null && config.tableUnavailable == null && !config.enabled)
          const _Banner('慢日志现在是关闭的，下面是之前记录下的。', kind: _BannerKind.warning),
        if (entries != null && entries.isEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text('mysql.slow_log 里没有记录', style: hint)),
        if (entries != null && entries.isNotEmpty)
          Expanded(
            child: ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return Container(
                  key: ValueKey('slow-entry-$index'),
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  padding: const EdgeInsets.all(8),
                  color: scheme.surfaceContainerHighest,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 16,
                        children: [
                          _cell(context, entry.startTime),
                          Row(mainAxisSize: MainAxisSize.min, children: [Text('耗时 ', style: hint), _cell(context, entry.queryTime)]),
                          Row(mainAxisSize: MainAxisSize.min, children: [Text('锁 ', style: hint), _cell(context, entry.lockTime)]),
                          Row(mainAxisSize: MainAxisSize.min, children: [Text('返回 ', style: hint), _cell(context, entry.rowsSent)]),
                          Row(mainAxisSize: MainAxisSize.min, children: [Text('扫描 ', style: hint), _cell(context, entry.rowsExamined)]),
                          Row(mainAxisSize: MainAxisSize.min, children: [Text('库 ', style: hint), _cell(context, entry.db)]),
                          _cell(context, entry.userHost),
                        ],
                      ),
                      const SizedBox(height: 4),
                      _cell(context, entry.sqlText, maxLines: null, selectable: true),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
