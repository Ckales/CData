import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data_source.dart';
import 'insert_row_dialog.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/layouts.dart';
import 'src/rust/api/value.dart';

/// 行号列的宽度。表头、数据行、总宽三处共用，漏掉任何一处都会让 Row 比容器宽
const double _rowNumberWidth = 64;

/// 结果网格。
///
/// 十万行留在 Rust 侧，这里任何时候只持有一个窗口。滚动到窗口外才去取下一段，
/// 不按单元格调 FFI，也不把整个结果集搬进 Dart。
class ResultGrid extends StatefulWidget {
  final GridSource source;

  /// 点列头排序。null 表示这个结果集不支持排序（比如还没跑过查询）
  final void Function(String column)? onSortColumn;

  /// 当前排序的列和方向，画箭头用
  final String? sortColumn;
  final bool sortAscending;

  const ResultGrid({
    super.key,
    required this.source,
    this.onSortColumn,
    this.sortColumn,
    this.sortAscending = true,
  });

  QuerySummary get summary => source.summary;

  @override
  State<ResultGrid> createState() => _ResultGridState();
}

class _ResultGridState extends State<ResultGrid> {
  /// 一次取多少行。比一屏多一截，滚动时不用每几行就往返一次
  static const int _windowSize = 200;

  /// 离窗口边缘还剩这么多行就预取下一段
  static const int _prefetchMargin = 40;

  static const double _defaultColumnWidth = 170;
  static const double _minColumnWidth = 48;
  static const double _maxAutoFitWidth = 600;
  static const double _rowHeight = 30;

  /// 显示顺序：第 n 个位置显示第 _order[n] 列。列下标始终指结果集里的原始位置
  late List<int> _order;

  /// 按原始列下标存的宽度
  late List<double> _widths;

  int _windowStart = 0;
  List<List<String>> _windowRows = [];

  /// 总行数。增删行后以 Rust 侧返回的为准，不在这里自己加减
  late int _totalRows = widget.summary.totalRows.toInt();

  /// 点行号选中的行，删除用
  final Set<int> _selected = {};
  final _scroll = ScrollController();

  bool _loading = false;
  String? _error;

  /// 正在编辑的单元格坐标，null 表示没有在编辑
  ({int row, int column})? _editing;
  final _editController = TextEditingController();

  /// 双击了不能改的单元格时的提示，显示在状态栏
  String? _refusal;

  @override
  void initState() {
    super.initState();
    _resetLayout();
    _loadLayout();
    _loadWindow(0);
  }

  @override
  void dispose() {
    _editController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ResultGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了查询就把窗口重置，否则会拿旧结果的行去渲染新结果
    if (oldWidget.source != widget.source) {
      _windowStart = 0;
      _windowRows = [];
      _totalRows = widget.summary.totalRows.toInt();
      _selected.clear();
      // 同一批列（比如点列头排序重跑）保留当前布局，换了列才重新读
      if (!listEquals(oldWidget.summary.columns, widget.summary.columns)) {
        _resetLayout();
        _loadLayout();
      }
      _loadWindow(0);
    }
  }

  void _resetLayout() {
    final count = widget.summary.columns.length;
    _order = [for (var i = 0; i < count; i++) i];
    _widths = List.filled(count, _defaultColumnWidth);
  }

  /// 按列名套用记住的布局。上次没记过的列（比如表新加了列）排在最后，用默认宽度
  Future<void> _loadLayout() async {
    final source = widget.source;
    final List<ColumnLayout> saved;
    try {
      saved = await source.loadLayout();
    } catch (e) {
      if (mounted) setState(() => _refusal = '读取列布局失败：$e');
      return;
    }
    // 读回来之前可能已经换了查询，旧布局不能套到新列上
    if (!mounted || widget.source != source || saved.isEmpty) return;

    final columns = widget.summary.columns;
    final order = <int>[];
    final widths = List<double>.filled(columns.length, _defaultColumnWidth);
    for (final item in saved) {
      for (var i = 0; i < columns.length; i++) {
        if (columns[i].name == item.name && !order.contains(i)) {
          order.add(i);
          widths[i] = item.width;
          break;
        }
      }
    }
    for (var i = 0; i < columns.length; i++) {
      if (!order.contains(i)) order.add(i);
    }

    setState(() {
      _order = order;
      _widths = widths;
    });
  }

  Future<void> _saveLayout() async {
    final columns = widget.summary.columns;
    final layout = [
      for (final i in _order) ColumnLayout(name: columns[i].name, width: _widths[i]),
    ];
    try {
      await widget.source.saveLayout(layout);
    } catch (e) {
      if (mounted) setState(() => _refusal = '保存列布局失败：$e');
    }
  }

  void _resizeColumn(int column, double delta) {
    setState(() => _widths[column] = math.max(_minColumnWidth, _widths[column] + delta));
  }

  /// 双击列边：按表头和已取回的行算出刚好放得下的宽度
  void _autoFitColumn(int column) {
    const headerStyle = TextStyle(fontWeight: FontWeight.w600, fontSize: 12);
    const cellStyle = TextStyle(fontSize: 12, fontFamily: 'Menlo');

    // 表头右边还要留出排序箭头（12）和拖拽柄（6）
    var widest = _textWidth(widget.summary.columns[column].name, headerStyle) + 18;
    // ponytail: 只量当前窗口（最多 200 行），不为了自适应去扫整个结果集
    for (final row in _windowRows) {
      widest = math.max(widest, _textWidth(row[column], cellStyle));
    }

    setState(() => _widths[column] = (widest + 16).clamp(_minColumnWidth, _maxAutoFitWidth));
    _saveLayout();
  }

  double _textWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// 把列挪到第 position 个位置，原来在那儿的往后让
  void _moveColumn(int column, int position) {
    setState(() {
      _order.remove(column);
      _order.insert(position.clamp(0, _order.length), column);
    });
    _saveLayout();
  }

  Future<void> _loadWindow(int start, {bool force = false}) async {
    if (_loading && !force) return;
    setState(() => _loading = true);

    try {
      final rows = await widget.source.windowText(start, _windowSize);
      if (!mounted) return;
      setState(() {
        _windowStart = start;
        _windowRows = rows;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 返回该行的单元格文本；不在当前窗口内就触发预取并返回 null
  List<String>? _rowAt(int index) {
    final offset = index - _windowStart;
    if (offset >= 0 && offset < _windowRows.length) {
      // 窗口后面还有没取的行，且快滚到边缘了，就提前拉下一段。
      // hasMoreAfter 这个条件不能省：结果集比 _prefetchMargin 还短时
      // `offset > length - margin` 恒为真，会一直往后预取到空窗口、再跳回来，
      // 两边来回震荡，每帧都发一次请求。
      final hasMoreAfter = _windowStart + _windowRows.length < _totalRows;
      if (hasMoreAfter && offset > _windowRows.length - _prefetchMargin) {
        _scheduleLoad(_windowStart + _windowSize - _prefetchMargin);
      } else if (_windowStart > 0 && offset < _prefetchMargin) {
        _scheduleLoad((_windowStart - _windowSize + _prefetchMargin).clamp(0, index));
      }
      return _windowRows[offset];
    }

    // 跳到了窗口之外（比如拖动滚动条），以这一行为中心重新取
    _scheduleLoad((index - _windowSize ~/ 2).clamp(0, _totalRows));
    return null;
  }

  /// 双击进入编辑。先取原始值判断能不能改 —— 不从显示文本反推类型
  Future<void> _beginEdit(int rowIndex, int columnIndex) async {
    setState(() => _refusal = null);

    final editability = widget.summary.editability;
    if (editability is Editability_ReadOnly) {
      setState(() => _refusal = editability.field0);
      return;
    }
    final target = (editability as Editability_Editable).field0;

    // keyIndexes 是 FRB 的 Uint64List，元素是 BigInt（u64 装不进 Dart 的 int）。
    // contains 收 Object?，拿 int 去比会永远 false 而且编译不报错
    if (target.keyIndexes.contains(BigInt.from(columnIndex))) {
      setState(() => _refusal = '${widget.summary.columns[columnIndex].name} 是主键列，改主键要用专门的流程');
      return;
    }

    final List<CellValue> row;
    try {
      row = await widget.source.row(rowIndex);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
      return;
    }
    if (!mounted || row.isEmpty) return;

    final cell = row[columnIndex];
    switch (cell) {
      case CellValue_Bytes():
      case CellValue_InvalidText():
        setState(() => _refusal = '二进制内容暂不支持在网格里编辑');
        return;
      case CellValue_Null():
        _editController.text = '';
      case CellValue_Int(:final field0):
        _editController.text = field0.toString();
      case CellValue_UInt(:final field0):
        _editController.text = field0.toString();
      case CellValue_Double(:final field0):
        _editController.text = field0.toString();
      case CellValue_Text(:final field0):
        _editController.text = field0;
    }

    setState(() => _editing = (row: rowIndex, column: columnIndex));
  }

  Future<void> _commitEdit(CellValue newValue) async {
    final editing = _editing;
    if (editing == null) return;

    setState(() => _editing = null);
    try {
      await widget.source.edit(editing.row, editing.column, newValue);
      await _loadWindow(_windowStart, force: true);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
    }
  }

  void _toggleSelected(int rowIndex) {
    setState(() {
      if (!_selected.remove(rowIndex)) _selected.add(rowIndex);
    });
  }

  Future<void> _insertRow() async {
    setState(() => _refusal = null);
    final values = await showInsertRowDialog(context, widget.summary.columns);
    if (values == null || !mounted) return;

    try {
      final total = await widget.source.insertRow(values);
      if (!mounted) return;
      setState(() {
        _totalRows = total;
        _editing = null;
      });
      // 新行追加在末尾：窗口挪到结尾并滚过去，插完就能看到库里实际存下的值
      await _loadWindow(math.max(0, total - _windowSize), force: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
    }
  }

  /// 删选中的行。直接写库、不能撤销，所以不管几行都要确认
  Future<void> _deleteSelected() async {
    final rows = _selected.toList()..sort();
    setState(() => _refusal = null);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${rows.length} 行？', style: const TextStyle(fontSize: 16)),
        content: const Text(
          '直接写入数据库，不能撤销。\n所有行在一个事务里删除，任何一行没删成都会整体回滚。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final total = await widget.source.deleteRows(rows);
      if (!mounted) return;
      setState(() {
        _totalRows = total;
        _selected.clear();
        _editing = null;
      });
      await _loadWindow(math.min(_windowStart, math.max(0, total - _windowSize)), force: true);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
    }
  }

  void _scheduleLoad(int start) {
    if (_loading || start == _windowStart) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // widget 可能在这一帧之后就被销毁了，不检查的话会对着已销毁的 state 发请求，
      // 请求还挂在那里没人收 —— 测试里表现为越跑越慢
      if (!mounted) return;
      _loadWindow(start);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('取数据失败：$_error', style: const TextStyle(color: Colors.red)),
        ),
      );
    }

    final columns = widget.summary.columns;
    var totalWidth = _rowNumberWidth;
    for (final width in _widths) {
      totalWidth += width;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.summary.truncated) const _TruncationBanner(),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: totalWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HeaderRow(
                    columns: columns,
                    order: _order,
                    widths: _widths,
                    onResize: _resizeColumn,
                    onResizeEnd: _saveLayout,
                    onAutoFit: _autoFitColumn,
                    onMove: _moveColumn,
                    onSortColumn: widget.onSortColumn,
                    sortColumn: widget.sortColumn,
                    sortAscending: widget.sortAscending,
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: _scroll,
                      itemCount: _totalRows,
                      itemExtent: _rowHeight,
                      itemBuilder: (context, index) {
                        final cells = _rowAt(index);
                        final editing = _editing;
                        return _DataRow(
                          rowNumber: index + 1,
                          selected: _selected.contains(index),
                          onTapRowNumber: () => _toggleSelected(index),
                          cells: cells,
                          order: _order,
                          widths: _widths,
                          editingColumn:
                              editing != null && editing.row == index ? editing.column : null,
                          editController: _editController,
                          onDoubleTapCell: (column) => _beginEdit(index, column),
                          onCommit: (text) => _commitEdit(CellValue.text(text)),
                          onSetNull: () => _commitEdit(const CellValue.null_()),
                          onCancel: () => setState(() => _editing = null),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _StatusBar(
          totalRows: _totalRows,
          loading: _loading,
          editability: widget.summary.editability,
          refusal: _refusal,
          selectedCount: _selected.length,
          onInsert: _insertRow,
          onDeleteSelected: _deleteSelected,
        ),
      ],
    );
  }
}

class _TruncationBanner extends StatelessWidget {
  const _TruncationBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: const Text(
        '结果已截断：实际行数超过上限，下面显示的不是全部数据。请加 LIMIT 或缩小条件。',
        style: TextStyle(fontSize: 12),
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final List<ColumnMeta> columns;
  final List<int> order;
  final List<double> widths;
  final void Function(int column, double delta) onResize;
  final VoidCallback onResizeEnd;
  final void Function(int column) onAutoFit;
  final void Function(int column, int position) onMove;
  final void Function(String column)? onSortColumn;
  final String? sortColumn;
  final bool sortAscending;

  const _HeaderRow({
    required this.columns,
    required this.order,
    required this.widths,
    required this.onResize,
    required this.onResizeEnd,
    required this.onAutoFit,
    required this.onMove,
    required this.onSortColumn,
    required this.sortColumn,
    required this.sortAscending,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: const Border(bottom: BorderSide(color: Colors.black26)),
      ),
      child: Row(
        children: [
          const SizedBox(width: _rowNumberWidth),
          for (var position = 0; position < order.length; position++)
            _cell(context, position, order[position]),
        ],
      ),
    );
  }

  /// 一个列头：左边拖动换位置、点击排序，右边的窄条拖动改宽度、双击自适应
  Widget _cell(BuildContext context, int position, int index) {
    final column = columns[index];
    final label = Text(
      column.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
    );

    return SizedBox(
      key: ValueKey('header-$index'),
      width: widths[index],
      child: Row(
        children: [
          Expanded(
            child: DragTarget<int>(
              onWillAcceptWithDetails: (details) => details.data != index,
              onAcceptWithDetails: (details) => onMove(details.data, position),
              builder: (context, candidates, _) => Draggable<int>(
                data: index,
                axis: Axis.horizontal,
                feedback: Material(
                  elevation: 4,
                  child: Container(
                    width: widths[index],
                    height: 32,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: label,
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.4, child: label),
                child: DecoratedBox(
                  // 拖到这一列上时画左边线，表示会插到这里
                  decoration: BoxDecoration(
                    border: candidates.isEmpty
                        ? null
                        : Border(
                            left: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 2,
                            ),
                          ),
                  ),
                  child: InkWell(
                    onTap: onSortColumn == null ? null : () => onSortColumn!(column.name),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Row(
                        children: [
                          Expanded(child: label),
                          if (sortColumn == column.name)
                            Icon(
                              sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                              size: 12,
                              color: Colors.black54,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              key: ValueKey('resize-$index'),
              behavior: HitTestBehavior.opaque,
              // 从按下的点算位移，不然越过拖动阈值前的那一段会丢，列边跟不上鼠标
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragUpdate: (details) => onResize(index, details.delta.dx),
              onHorizontalDragEnd: (_) => onResizeEnd(),
              onDoubleTap: () => onAutoFit(index),
              child: const SizedBox(
                width: 6,
                height: 32,
                child: Center(child: SizedBox(width: 1, height: 16, child: ColoredBox(color: Colors.black26))),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DataRow extends StatelessWidget {
  final int rowNumber;
  final bool selected;
  final VoidCallback onTapRowNumber;
  final List<String>? cells;
  final List<int> order;
  final List<double> widths;
  final int? editingColumn;
  final TextEditingController editController;
  final void Function(int column) onDoubleTapCell;
  final void Function(String text) onCommit;
  final VoidCallback onSetNull;
  final VoidCallback onCancel;

  const _DataRow({
    required this.rowNumber,
    required this.selected,
    required this.onTapRowNumber,
    required this.cells,
    required this.order,
    required this.widths,
    required this.editingColumn,
    required this.editController,
    required this.onDoubleTapCell,
    required this.onCommit,
    required this.onSetNull,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
            : rowNumber.isEven
                ? Colors.black.withValues(alpha: 0.02)
                : null,
        border: const Border(bottom: BorderSide(color: Colors.black12)),
      ),
      child: Row(
        children: [
          GestureDetector(
            key: ValueKey('row-number-${rowNumber - 1}'),
            behavior: HitTestBehavior.opaque,
            onTap: onTapRowNumber,
            child: SizedBox(
              width: _rowNumberWidth,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '$rowNumber',
                    style: const TextStyle(fontSize: 11, color: Colors.black45),
                  ),
                ),
              ),
            ),
          ),
          for (final i in order)
            SizedBox(
              // 行号列和数据列可能显示一样的文本，测试要靠 key 才能精确定位。
              // i 是结果集里的原始列下标，和显示顺序无关
              key: ValueKey('cell-${rowNumber - 1}-$i'),
              width: widths[i],
              child: editingColumn == i
                  ? _CellEditor(
                      controller: editController,
                      onCommit: onCommit,
                      onSetNull: onSetNull,
                      onCancel: onCancel,
                    )
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTap: () => onDoubleTapCell(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _CellText(text: cells?[i]),
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

/// 单元格编辑框。Enter 提交，Esc 取消，∅ 写 NULL。
///
/// NULL 要有独立入口：清空输入提交的是空字符串，和 NULL 是两回事，不能靠猜。
class _CellEditor extends StatelessWidget {
  final TextEditingController controller;
  final void Function(String text) onCommit;
  final VoidCallback onSetNull;
  final VoidCallback onCancel;

  const _CellEditor({
    required this.controller,
    required this.onCommit,
    required this.onSetNull,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Focus(
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                onCancel();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              ),
              onSubmitted: onCommit,
            ),
          ),
        ),
        Tooltip(
          message: '写入 NULL',
          child: InkWell(
            onTap: onSetNull,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text('∅', style: TextStyle(fontSize: 13, color: Colors.black54)),
            ),
          ),
        ),
      ],
    );
  }
}

/// NULL 和占位内容要看得出来和普通文本不同，否则分不清「空值」和「空字符串」
class _CellText extends StatelessWidget {
  final String? text;

  const _CellText({required this.text});

  @override
  Widget build(BuildContext context) {
    if (text == null) {
      return const Text('', style: TextStyle(fontSize: 12));
    }

    final isPlaceholder = text == 'NULL' || (text!.startsWith('<') && text!.endsWith('>'));
    return Text(
      text!,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontFamily: 'Menlo',
        color: isPlaceholder ? Colors.black38 : null,
        fontStyle: isPlaceholder ? FontStyle.italic : null,
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final int totalRows;
  final bool loading;
  final Editability editability;
  final String? refusal;
  final int selectedCount;
  final VoidCallback onInsert;
  final VoidCallback onDeleteSelected;

  const _StatusBar({
    required this.totalRows,
    required this.loading,
    required this.editability,
    required this.refusal,
    required this.selectedCount,
    required this.onInsert,
    required this.onDeleteSelected,
  });

  @override
  Widget build(BuildContext context) {
    final readOnlyReason = switch (editability) {
      Editability_ReadOnly(:final field0) => field0,
      Editability_Editable() => null,
    };
    final message = refusal ?? readOnlyReason;

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: const Border(top: BorderSide(color: Colors.black26)),
      ),
      child: Row(
        children: [
          Text('$totalRows 行', style: const TextStyle(fontSize: 11)),
          const SizedBox(width: 12),
          if (message != null)
            Expanded(
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: refusal != null ? Colors.red.shade700 : Colors.black54,
                ),
              ),
            )
          else
            const Expanded(
              child: Text(
                '双击单元格编辑，点行号选中行',
                style: TextStyle(fontSize: 11, color: Colors.black38),
              ),
            ),
          // 刻意不用 CircularProgressIndicator：它是无限动画，会让 pumpAndSettle
          // 永远等不到"稳定"，测试直接挂死。静态文字一样能表达状态
          if (loading)
            const Text('加载中…', style: TextStyle(fontSize: 11, color: Colors.black45)),
          // 只读结果集不给增删入口，原因已经显示在左边
          if (readOnlyReason == null) ...[
            if (selectedCount > 0)
              _BarButton(
                label: '删除 $selectedCount 行',
                color: Colors.red.shade700,
                onPressed: onDeleteSelected,
              ),
            _BarButton(label: '新增行', onPressed: onInsert),
          ],
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  final String label;
  final Color? color;
  final VoidCallback onPressed;

  const _BarButton({required this.label, required this.onPressed, this.color});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 22),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 11),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}
