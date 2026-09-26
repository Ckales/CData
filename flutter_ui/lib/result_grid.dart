import 'dart:async' show Timer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show DragStartBehavior, PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data_source.dart';
import 'package:file_selector/file_selector.dart' show XTypeGroup, getSaveLocation;

import 'cell_editors.dart';
import 'export_dialog.dart';
import 'insert_row_dialog.dart';
import 'mac_widgets.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/layouts.dart';
import 'src/rust/api/value.dart';
import 'theme.dart';

Future<String?> _systemSavePath(String suggestedName) async {
  final extension = suggestedName.split('.').last;
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: [XTypeGroup(label: extension.toUpperCase(), extensions: [extension])],
  );
  return location?.path;
}

/// 行号列的宽度。表头、数据行、总宽三处共用，漏掉任何一处都会让 Row 比容器宽
const double _rowNumberWidth = 48;

/// 表头高度。Querious 的表头很矮，和工具栏一样浅灰
const double _headerHeight = 22;

/// 单元格和表头的字：系统字体 12px，不用等宽字体（Querious 也是系统字体）
const _cellStyle = TextStyle(fontSize: 12);
const _headerStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w500);

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

  /// 选导出文件的保存位置，返回 null 表示取消。不传就弹系统保存对话框，测试里换掉
  final Future<String?> Function(String suggestedName)? pickSavePath;

  /// 校验 TIME 输入，返回错误说明，合法返回 null。不传就调 core 的 checkTimeText，测试里换掉
  final String? Function(String text, int fsp)? checkTime;

  /// 右键「加入筛选」：带着列名和这一格的原始值交给查询页。null 表示这个结果集不能筛选
  final void Function(String column, CellValue value)? onAddToSearch;

  /// 右键「刷新全部行」：重新执行查询。null 表示这个结果集不能单独重跑（脚本结果、执行计划）
  final VoidCallback? onRefreshAll;

  const ResultGrid({
    super.key,
    required this.source,
    this.onSortColumn,
    this.sortColumn,
    this.sortAscending = true,
    this.pickSavePath,
    this.checkTime,
    this.onAddToSearch,
    this.onRefreshAll,
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
  static const double _rowHeight = 20;

  /// 显示顺序：第 n 个位置显示第 _order[n] 列。列下标始终指结果集里的原始位置
  late List<int> _order;

  /// 按原始列下标存的宽度
  late List<double> _widths;

  int _windowStart = 0;
  List<List<DisplayCell>> _windowRows = [];

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

  /// 编辑框的焦点。不能靠 autofocus：按下单元格时网格已经拿了焦点，
  /// autofocus 只在作用域里没有焦点时才生效，结果是编辑框开了、打字却没反应
  final _editFocus = FocusNode(debugLabel: 'cell-editor');

  /// 双击了不能改的单元格时的提示，显示在状态栏
  String? _refusal;

  /// 操作成功的提示（复制了几格、写了几格），灰字显示在状态栏
  String? _notice;

  /// 单元格选区的两个角：锚点（普通点击）和另一角（Shift 点击）。
  /// 列是显示位置而不是原始列下标，换了列顺序后选区跟着屏幕走
  ({int row, int position})? _anchor;
  ({int row, int position})? _corner;

  /// 网格本身的焦点。复制粘贴、方向键只在它拿着焦点时接管：编辑框里的 ⌘C 归编辑框，
  /// SQL 编辑器里的方向键归编辑器（它不在网格下面，事件根本到不了这里）
  final _gridFocus = FocusNode(debugLabel: 'result-grid');

  /// 横向滚动。键盘移到屏幕外的列、拖选到边缘时要滚过去
  final _hScroll = ScrollController();

  /// 鼠标按在单元格上拖动选区中。只认鼠标：触摸和触控板的拖动是滚动
  bool _dragging = false;

  /// 拖选时指针相对可视区的位置，自动滚动每一拍都按它重新算落在哪一格
  Offset? _dragPointer;
  Timer? _autoScroll;

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
    _editFocus.dispose();
    _scroll.dispose();
    _hScroll.dispose();
    _gridFocus.dispose();
    _autoScroll?.cancel();
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
      _anchor = null;
      _corner = null;
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
    final layout = [for (final i in _order) ColumnLayout(name: columns[i].name, width: _widths[i])];
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
    // 表头右边还要留出排序箭头（14）和拖拽柄（6）
    var widest = _textWidth(widget.summary.columns[column].name, _headerStyle) + 20;
    // ponytail: 只量当前窗口（最多 200 行），不为了自适应去扫整个结果集
    for (final row in _windowRows) {
      widest = math.max(widest, _textWidth(row[column].text, _cellStyle));
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
  List<DisplayCell>? _rowAt(int index) {
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

  /// 这一列不能改的原因，能改返回 null
  String? _editRefusal(int columnIndex) {
    final editability = widget.summary.editability;
    if (editability is Editability_ReadOnly) return editability.field0;
    final target = (editability as Editability_Editable).field0;

    // keyIndexes 是 FRB 的 Uint64List，元素是 BigInt（u64 装不进 Dart 的 int）。
    // contains 收 Object?，拿 int 去比会永远 false 而且编译不报错
    if (target.keyIndexes.contains(BigInt.from(columnIndex))) {
      return '${widget.summary.columns[columnIndex].name} 是主键列，改主键要用专门的流程';
    }
    return null;
  }

  /// 双击进入编辑。先取原始值判断能不能改 —— 不从显示文本反推类型
  Future<void> _beginEdit(int rowIndex, int columnIndex) async {
    final refusal = _editRefusal(columnIndex);
    setState(() => _refusal = refusal);
    if (refusal != null) return;

    final List<CellValue> row;
    try {
      row = await widget.source.row(rowIndex);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
      return;
    }
    if (!mounted || row.isEmpty) return;

    final column = widget.summary.columns[columnIndex];
    final cell = row[columnIndex];
    // 当前值的文本；null 表示当前是 NULL
    final String? current;
    switch (cell) {
      case CellValue_Bytes(:final field0):
        await _showHex(column.name, field0, invalidText: false);
        return;
      case CellValue_InvalidText(:final field0):
        await _showHex(column.name, field0, invalidText: true);
        return;
      case CellValue_Null():
        current = null;
      case CellValue_Int(:final field0):
        current = field0.toString();
      case CellValue_UInt(:final field0):
        current = field0.toString();
      case CellValue_Double(:final field0):
        current = field0.toString();
      case CellValue_Text(:final field0):
        current = field0;
    }

    if (!mounted) return;
    // 按列类别选编辑器。类别来自列元数据，不从值反推
    final CellValue? value;
    switch (column.kind) {
      case ColumnKind.binary:
        setState(() => _refusal = '二进制内容暂不支持在网格里编辑');
        return;
      case ColumnKind.json:
        value = await showJsonEditor(
          context,
          column: column.name,
          initial: current ?? '',
          format: widget.source.formatJson,
        );
      case ColumnKind.enum_:
      case ColumnKind.set_:
        final List<String> choices;
        try {
          choices = await widget.source.columnChoices(columnIndex);
        } catch (e) {
          if (mounted) setState(() => _refusal = '$e');
          return;
        }
        if (!mounted) return;
        value = column.kind == ColumnKind.enum_
            ? await showEnumEditor(context, column: column.name, choices: choices, current: current)
            : await showSetEditor(context, column: column.name, choices: choices, current: current);
      case ColumnKind.date:
      case ColumnKind.dateTime:
        value = await showDateEditor(
          context,
          column: column.name,
          initial: current ?? '',
          withTime: column.kind == ColumnKind.dateTime,
        );
      case ColumnKind.time:
        value = await showTimeEditor(
          context,
          column: column.name,
          initial: current ?? '',
          fsp: column.decimals,
          check: (text) => _checkTime(text, column.decimals),
        );
      case ColumnKind.text:
      case ColumnKind.number:
        _editController.text = current ?? '';
        _startInlineEdit(rowIndex, columnIndex);
        return;
    }

    if (value != null) await _writeCell(rowIndex, columnIndex, value);
  }

  /// TIME 的格式和范围只在 core 里判断，这里把错误说明交给编辑器显示
  String? _checkTime(String text, int fsp) {
    final check = widget.checkTime;
    if (check != null) return check(text, fsp);
    try {
      checkTimeText(text: text, fsp: fsp);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<void> _showHex(String column, Uint8List bytes, {required bool invalidText}) async {
    final String dump;
    try {
      dump = await widget.source.hexDump(bytes);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
      return;
    }
    if (!mounted) return;
    await showHexViewer(
      context,
      column: column,
      dump: dump,
      byteCount: bytes.length,
      invalidText: invalidText,
    );
  }

  void _startInlineEdit(int rowIndex, int columnIndex) {
    setState(() => _editing = (row: rowIndex, column: columnIndex));
    // 编辑框这一帧才建出来，建好再给焦点
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing != null) _editFocus.requestFocus();
    });
  }

  Future<void> _commitEdit(CellValue newValue) async {
    final editing = _editing;
    if (editing == null) return;

    setState(() => _editing = null);
    // 编辑框拆掉后焦点会退到路由那一层，收回来才能接着用方向键
    _gridFocus.requestFocus();
    await _writeCell(editing.row, editing.column, newValue);
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _gridFocus.requestFocus();
  }

  /// 右键「设为 NULL」。直接写库，和编辑框里的 ∅ 一样不再确认
  Future<void> _setNull(int rowIndex, int columnIndex) async {
    final refusal = _editRefusal(columnIndex);
    setState(() => _refusal = refusal);
    if (refusal != null) return;
    await _writeCell(rowIndex, columnIndex, const CellValue.null_());
  }

  Future<void> _writeCell(int rowIndex, int columnIndex, CellValue value) async {
    try {
      await widget.source.edit(rowIndex, columnIndex, value);
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

  /// 新增一行。initial 是「复制行」带进来的原值
  Future<void> _insertRow({List<CellValue?>? initial}) async {
    setState(() => _refusal = null);
    final values = await showInsertRowDialog(context, widget.summary.columns, initial: initial);
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

  /// 复制行：拿这一行的原始值预填新增行表单。主键交给默认 / 自增，否则一定撞主键
  Future<void> _duplicateRow(int rowIndex) async {
    final editability = widget.summary.editability;
    if (editability is Editability_ReadOnly) {
      setState(() => _refusal = editability.field0);
      return;
    }
    final target = (editability as Editability_Editable).field0;

    final List<CellValue> row;
    try {
      row = await widget.source.row(rowIndex);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
      return;
    }
    if (!mounted || row.isEmpty) return;

    final initial = <CellValue?>[];
    for (var i = 0; i < row.length; i++) {
      initial.add(target.keyIndexes.contains(BigInt.from(i)) ? null : row[i]);
    }
    await _insertRow(initial: initial);
  }

  /// 按主键从库里重读这一行
  Future<void> _refreshRow(int rowIndex) async {
    setState(() {
      _refusal = null;
      _notice = null;
    });
    try {
      await widget.source.refreshRow(rowIndex);
      await _loadWindow(_windowStart, force: true);
      if (mounted) setState(() => _notice = '已刷新第 ${rowIndex + 1} 行');
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
    }
  }

  /// 右键「加入筛选」：取这一格的原始值交给查询页，不从显示文本反推
  Future<void> _addToSearch(int rowIndex, int columnIndex) async {
    final onAddToSearch = widget.onAddToSearch;
    if (onAddToSearch == null) return;
    final List<CellValue> row;
    try {
      row = await widget.source.row(rowIndex);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
      return;
    }
    if (!mounted || row.isEmpty) return;
    onAddToSearch(widget.summary.columns[columnIndex].name, row[columnIndex]);
  }

  /// 删若干行。直接写库、不能撤销，所以不管几行都要确认
  Future<void> _deleteRows(List<int> rows) async {
    setState(() => _refusal = null);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${rows.length} 行？'),
        content: const Text('直接写入数据库，不能撤销。\n所有行在一个事务里删除，任何一行没删成都会整体回滚。'),
        actions: [
          OutlinedButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
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
        _anchor = null;
        _corner = null;
      });
      await _loadWindow(math.min(_windowStart, math.max(0, total - _windowSize)), force: true);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
    }
  }

  /// 选区的上下左右边界，都是闭区间
  ({int top, int bottom, int left, int right})? get _range {
    final anchor = _anchor;
    final corner = _corner;
    if (anchor == null || corner == null) return null;
    return (
      top: math.min(anchor.row, corner.row),
      bottom: math.max(anchor.row, corner.row),
      left: math.min(anchor.position, corner.position),
      right: math.max(anchor.position, corner.position),
    );
  }

  void _selectCell(PointerDownEvent event, int row, int position) {
    _gridFocus.requestFocus();
    _dragging = event.kind == PointerDeviceKind.mouse;
    setState(() {
      _notice = null;
      if (HardwareKeyboard.instance.isShiftPressed && _anchor != null) {
        _corner = (row: row, position: position);
      } else {
        _anchor = (row: row, position: position);
        _corner = _anchor;
      }
    });
  }

  /// 按下单元格后拖动：另一角跟着指针走，贴近或越过可视区边缘时自动滚动。
  /// local 是数据区里的坐标，横向已经含了滚动偏移
  void _dragMove(PointerMoveEvent event) {
    if (!_dragging) return;
    final horizontal = _hScroll.hasClients ? _hScroll.offset : 0.0;
    _dragPointer = Offset(event.localPosition.dx - horizontal, event.localPosition.dy);
    _dragExtend();
    _autoScroll ??= Timer.periodic(const Duration(milliseconds: 50), (_) => _autoScrollTick());
  }

  void _dragEnd(PointerEvent event) {
    _dragging = false;
    _dragPointer = null;
    _autoScroll?.cancel();
    _autoScroll = null;
  }

  /// 把选区的另一角放到指针所在的格。越出上下左右边界的按最近的格算
  void _dragExtend() {
    final pointer = _dragPointer;
    if (pointer == null || _anchor == null || _totalRows == 0 || _order.isEmpty) return;

    final vertical = _scroll.hasClients ? _scroll.offset : 0.0;
    final horizontal = _hScroll.hasClients ? _hScroll.offset : 0.0;
    final row = ((pointer.dy + vertical) / _rowHeight).floor().clamp(0, _totalRows - 1);
    final x = pointer.dx + horizontal;
    var left = _rowNumberWidth;
    var position = _order.length - 1;
    for (var i = 0; i < _order.length; i++) {
      left += _widths[_order[i]];
      if (x < left) {
        position = i;
        break;
      }
    }

    final corner = (row: row, position: position);
    if (corner != _corner) setState(() => _corner = corner);
  }

  /// 拖选时指针离边缘越近（或越出越远）滚得越快，一拍最多三行
  void _autoScrollTick() {
    final pointer = _dragPointer;
    if (pointer == null || !_scroll.hasClients) return;
    const edge = 24.0;
    const maxStep = _rowHeight * 3;

    double overshoot(double at, double extent) {
      if (at < edge) return (at - edge).clamp(-maxStep, 0);
      if (at > extent - edge) return (at - extent + edge).clamp(0, maxStep);
      return 0;
    }

    var moved = false;
    final vertical = _scroll.position;
    final dy = overshoot(pointer.dy, vertical.viewportDimension);
    if (dy != 0) {
      final target = (vertical.pixels + dy).clamp(0.0, vertical.maxScrollExtent);
      moved = target != vertical.pixels;
      vertical.jumpTo(target);
    }
    if (_hScroll.hasClients) {
      final horizontal = _hScroll.position;
      final dx = overshoot(pointer.dx, horizontal.viewportDimension);
      if (dx != 0) {
        final target = (horizontal.pixels + dx).clamp(0.0, horizontal.maxScrollExtent);
        moved = moved || target != horizontal.pixels;
        horizontal.jumpTo(target);
      }
    }
    // 滚动时内容在指针下移动了，另一角要跟着换
    if (moved) _dragExtend();
  }

  /// 可视区能放下几行，PageUp / PageDown 按这个翻
  int get _pageRows {
    if (!_scroll.hasClients) return 10;
    return math.max(1, (_scroll.position.viewportDimension / _rowHeight).floor() - 1);
  }

  /// 键盘移动当前格。extend 为 true 时只动选区的另一角（Shift），当前格不变
  void _moveTo(int row, int position, {required bool extend}) {
    final cell = (row: row.clamp(0, _totalRows - 1), position: position.clamp(0, _order.length - 1));
    setState(() {
      _notice = null;
      if (extend && _anchor != null) {
        _corner = cell;
      } else {
        _anchor = cell;
        _corner = cell;
      }
    });
    _reveal(cell.row, cell.position);
  }

  /// 把这一格滚进可视区。滚过去之后 ListView 建出那几行，_rowAt 会去取这一段的数据
  void _reveal(int row, int position) {
    if (_scroll.hasClients) {
      final vertical = _scroll.position;
      final top = row * _rowHeight;
      var target = vertical.pixels;
      if (top < target) target = top;
      if (top + _rowHeight > target + vertical.viewportDimension) {
        target = top + _rowHeight - vertical.viewportDimension;
      }
      vertical.jumpTo(target.clamp(0.0, vertical.maxScrollExtent));
    }
    if (_hScroll.hasClients) {
      final horizontal = _hScroll.position;
      var left = _rowNumberWidth;
      for (var i = 0; i < position; i++) {
        left += _widths[_order[i]];
      }
      final right = left + _widths[_order[position]];
      // 行号列跟着内容横向滚动；回到第一列时连行号一起露出来
      var target = horizontal.pixels;
      if (left < target) target = position == 0 ? 0 : left;
      if (right > target + horizontal.viewportDimension) target = right - horizontal.viewportDimension;
      horizontal.jumpTo(target.clamp(0.0, horizontal.maxScrollExtent));
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // 编辑框拿着焦点时事件也会冒泡到这里，那时的按键都归编辑框
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;

    // macOS 用 ⌘，Windows 用 Ctrl，两个都认
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isMetaPressed || keyboard.isControlPressed;
    final key = event.logicalKey;

    // 复制粘贴不跟着按住连发，否则按久了会弹出一串确认框
    if (command && event is KeyDownEvent && key == LogicalKeyboardKey.keyC) {
      _copySelection();
      return KeyEventResult.handled;
    }
    if (command && event is KeyDownEvent && key == LogicalKeyboardKey.keyV) {
      _pasteFromClipboard();
      return KeyEventResult.handled;
    }
    return _handleNavigationKey(key, command: command, shift: keyboard.isShiftPressed, alt: keyboard.isAltPressed);
  }

  /// 方向键、Home / End、翻页、Enter / F2、Esc。不认的组合一律放行，
  /// 外层的 ⌘T / ⌘W 之类快捷键要能收到
  KeyEventResult _handleNavigationKey(
    LogicalKeyboardKey key, {
    required bool command,
    required bool shift,
    required bool alt,
  }) {
    if (alt || _totalRows == 0 || _order.isEmpty) return KeyEventResult.ignored;
    final anchor = _anchor;

    if (!command && key == LogicalKeyboardKey.escape) {
      if (anchor == null) return KeyEventResult.ignored;
      setState(() {
        _anchor = null;
        _corner = null;
      });
      return KeyEventResult.handled;
    }
    if (!command &&
        !shift &&
        (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.f2)) {
      if (anchor == null) return KeyEventResult.ignored;
      _reveal(anchor.row, anchor.position);
      _beginEdit(anchor.row, _order[anchor.position]);
      return KeyEventResult.handled;
    }

    final isHomeEnd = key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end;
    // ⌘ 只和 Home / End 组合（跳到首行 / 末行），⌘ + 方向键留给别人
    if (command && !isHomeEnd) return KeyEventResult.ignored;

    // Shift 挪的是选区的另一角，普通移动从当前格出发
    final from = shift ? _corner : anchor;
    final lastRow = _totalRows - 1;
    final lastPosition = _order.length - 1;
    int row;
    int position;
    if (from == null) {
      // 还没有当前格：第一下只选中可视区左上角那一格，不急着挪
      final firstVisible = _scroll.hasClients ? (_scroll.offset / _rowHeight).ceil() : 0;
      row = firstVisible;
      position = 0;
      if (!_isNavigationKey(key)) return KeyEventResult.ignored;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      row = from.row - 1;
      position = from.position;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      row = from.row + 1;
      position = from.position;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      row = from.row;
      position = from.position - 1;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      row = from.row;
      position = from.position + 1;
    } else if (key == LogicalKeyboardKey.pageUp) {
      row = from.row - _pageRows;
      position = from.position;
    } else if (key == LogicalKeyboardKey.pageDown) {
      row = from.row + _pageRows;
      position = from.position;
    } else if (key == LogicalKeyboardKey.home) {
      row = command ? 0 : from.row;
      position = 0;
    } else if (key == LogicalKeyboardKey.end) {
      row = command ? lastRow : from.row;
      position = lastPosition;
    } else {
      return KeyEventResult.ignored;
    }

    _moveTo(row, position, extend: shift && from != null);
    return KeyEventResult.handled;
  }

  bool _isNavigationKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
  }

  Future<void> _copySelection() async {
    final range = _range;
    if (range == null) return;
    await _copyCells(range.top, range.bottom - range.top + 1, _order.sublist(range.left, range.right + 1));
  }

  /// 复制一片单元格。编码在 Rust 侧做，NULL、二进制、带制表符的文本怎么写都在那里定
  Future<void> _copyCells(int rowStart, int rowCount, List<int> columns) async {
    try {
      final tsv = await widget.source.copyRange(rowStart, rowCount, columns);
      await Clipboard.setData(ClipboardData(text: tsv));
      if (!mounted) return;
      setState(() {
        _refusal = null;
        _notice = '已复制 $rowCount 行 × ${columns.length} 列';
      });
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
    }
  }

  /// 从选区左上角开始，按剪贴板内容的大小铺开粘贴。不按选区裁剪，也不重复填充
  Future<void> _pasteFromClipboard() async {
    final range = _range;
    if (range == null) return;
    setState(() {
      _refusal = null;
      _notice = null;
    });

    final editability = widget.summary.editability;
    if (editability is Editability_ReadOnly) {
      setState(() => _refusal = editability.field0);
      return;
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      setState(() => _refusal = '剪贴板里没有文本');
      return;
    }

    final List<List<CellValue>> values;
    try {
      values = await widget.source.parseClipboard(text);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
      return;
    }
    if (!mounted) return;

    final rowCount = values.length;
    final columnCount = values.first.length;
    // 显示位置换算成列下标是界面的事，放不下要在这里拦；行数 Rust 侧还会再核一次
    if (range.left + columnCount > _order.length) {
      setState(
        () => _refusal = '剪贴板有 $columnCount 列，从第 ${range.left + 1} 列开始放不下（共 ${_order.length} 列）',
      );
      return;
    }
    if (range.top + rowCount > _totalRows) {
      setState(
        () => _refusal = '剪贴板有 $rowCount 行，从第 ${range.top + 1} 行开始会超出结果集末尾（共 $_totalRows 行）',
      );
      return;
    }

    final firstColumn = widget.summary.columns[_order[range.left]].name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('粘贴 $rowCount 行 × $columnCount 列？'),
        content: Text(
          '从第 ${range.top + 1} 行的 $firstColumn 列开始覆盖，直接写入数据库，不能撤销。\n'
          '所有格子在一个事务里写入，任何一格没写成都会整体回滚。\n'
          '不带引号的 NULL 写成 NULL，空格子写成空字符串。',
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('粘贴')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final columns = _order.sublist(range.left, range.left + columnCount);
      final written = await widget.source.pasteCells(range.top, columns, values);
      if (!mounted) return;
      setState(() {
        _editing = null;
        _notice = '已写入 $written 个单元格';
        // 选区换成实际粘贴的那一块，方便核对
        _anchor = (row: range.top, position: range.left);
        _corner = (row: range.top + rowCount - 1, position: range.left + columnCount - 1);
      });
      await _loadWindow(_windowStart, force: true);
    } catch (e) {
      if (mounted) setState(() => _refusal = '$e');
    }
  }

  /// 导出全部或选中区域。列按屏幕上的顺序；行直接从 Rust 侧写文件
  Future<void> _export() async {
    final range = _range;
    final selectionLabel = range == null
        ? null
        : '${range.bottom - range.top + 1} 行 × ${range.right - range.left + 1} 列';
    final editability = widget.summary.editability;
    final suggestedTable = switch (editability) {
      Editability_Editable(:final field0) => field0.table,
      Editability_ReadOnly() => '',
    };

    final choice = await showExportDialog(
      context,
      totalRows: _totalRows,
      selectionLabel: selectionLabel,
      suggestedTable: suggestedTable,
    );
    if (choice == null || !mounted) return;

    final extension = choice.options.format == ExportFormat.csv ? 'csv' : 'sql';
    final baseName = suggestedTable.isEmpty ? 'result' : suggestedTable;
    final pickSavePath = widget.pickSavePath ?? _systemSavePath;
    final path = await pickSavePath('$baseName.$extension');
    if (path == null || !mounted) return;

    final useSelection = choice.selectionOnly && range != null;
    final columns = useSelection ? _order.sublist(range.left, range.right + 1) : [..._order];
    setState(() {
      _refusal = null;
      _notice = null;
    });
    try {
      final summary = await widget.source.exportRows(
        path,
        useSelection ? range.top : 0,
        useSelection ? range.bottom - range.top + 1 : null,
        columns,
        choice.options,
      );
      if (!mounted) return;
      setState(() {
        final written = '已导出 ${summary.rowsWritten} 行到 $path';
        if (summary.sourceTruncated) {
          // 截断过的结果导出去也是残缺的，用醒目的红字说
          _refusal = '$written，但结果集本身被截断过，文件里不是全部数据';
        } else {
          _notice = written;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _refusal = '导出失败：$e');
    }
  }

  /// 单元格右键菜单，按 Querious 的分组：值、行、表。
  /// 右键点在选区外就先选中这一格；点在选中的行上，删除作用于全部选中行
  Future<void> _showCellMenu(int row, int position, Offset globalPosition) async {
    _gridFocus.requestFocus();
    final range = _range;
    final inRange =
        range != null &&
        row >= range.top &&
        row <= range.bottom &&
        position >= range.left &&
        position <= range.right;
    if (!inRange) {
      setState(() {
        _anchor = (row: row, position: position);
        _corner = _anchor;
      });
    }

    final columnIndex = _order[position];
    final name = widget.summary.columns[columnIndex].name;
    final editable = widget.summary.editability is Editability_Editable;
    final rows = _selected.contains(row) ? (_selected.toList()..sort()) : [row];

    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(globalPosition.dx, globalPosition.dy, globalPosition.dx, globalPosition.dy),
      items: [
        PopupMenuItem(value: 'copy-value', height: 26, child: Text('复制 "$name" 的值')),
        PopupMenuItem(value: 'edit', height: 26, enabled: editable, child: Text('编辑 "$name" 的值…')),
        PopupMenuItem(value: 'null', height: 26, enabled: editable, child: Text('将 "$name" 设为 NULL')),
        if (widget.onAddToSearch != null) ...[
          const PopupMenuDivider(height: 8),
          PopupMenuItem(value: 'search', height: 26, child: Text('将 "$name" 加入筛选…')),
        ],
        const PopupMenuDivider(height: 8),
        PopupMenuItem(
          value: 'delete',
          height: 26,
          enabled: editable,
          child: Text(rows.length == 1 ? '删除行' : '删除 ${rows.length} 行'),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem(value: 'insert', height: 26, enabled: editable, child: const Text('新增行…')),
        PopupMenuItem(value: 'duplicate', height: 26, enabled: editable, child: const Text('复制为新行…')),
        const PopupMenuItem(value: 'copy-row', height: 26, child: Text('复制整行')),
        PopupMenuItem(value: 'refresh-row', height: 26, enabled: editable, child: const Text('刷新行')),
        const PopupMenuDivider(height: 8),
        if (widget.onRefreshAll != null)
          const PopupMenuItem(value: 'refresh-all', height: 26, child: Text('刷新全部行')),
        const PopupMenuItem(value: 'export', height: 26, child: Text('导出…')),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'copy-value':
        await _copyCells(row, 1, [columnIndex]);
      case 'edit':
        await _beginEdit(row, columnIndex);
      case 'null':
        await _setNull(row, columnIndex);
      case 'search':
        await _addToSearch(row, columnIndex);
      case 'duplicate':
        await _duplicateRow(row);
      case 'refresh-row':
        await _refreshRow(row);
      case 'refresh-all':
        widget.onRefreshAll?.call();
      case 'copy-row':
        await _copyCells(row, 1, [..._order]);
      case 'delete':
        await _deleteRows(rows);
      case 'insert':
        await _insertRow();
      case 'export':
        await _export();
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
          child: Text('取数据失败：$_error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
          child: Focus(
            focusNode: _gridFocus,
            onKeyEvent: _handleKey,
            child: SingleChildScrollView(
              controller: _hScroll,
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
                      // 拖选：按下由单元格自己接（知道是哪一格），之后的移动都送到这里，
                      // 指针拖出网格也照样收得到
                      child: Listener(
                        onPointerMove: _dragMove,
                        onPointerUp: _dragEnd,
                        onPointerCancel: _dragEnd,
                        child: ListView.builder(
                          controller: _scroll,
                          itemCount: _totalRows,
                          itemExtent: _rowHeight,
                          itemBuilder: (context, index) {
                            final cells = _rowAt(index);
                            final editing = _editing;
                            final range = _range;
                            return _DataRow(
                              selectedPositions:
                                  range != null && index >= range.top && index <= range.bottom
                                  ? (left: range.left, right: range.right)
                                  : null,
                              onPointerDownCell: (event, position) => _selectCell(event, index, position),
                              onSecondaryTapCell: (position, globalPosition) =>
                                  _showCellMenu(index, position, globalPosition),
                              rowNumber: index + 1,
                              selected: _selected.contains(index),
                              onTapRowNumber: () => _toggleSelected(index),
                              cells: cells,
                              columns: columns,
                              order: _order,
                              widths: _widths,
                              editingColumn: editing != null && editing.row == index
                                  ? editing.column
                                  : null,
                              editController: _editController,
                              editFocus: _editFocus,
                              onDoubleTapCell: (column) => _beginEdit(index, column),
                              onCommit: (text) => _commitEdit(CellValue.text(text)),
                              onSetNull: () => _commitEdit(const CellValue.null_()),
                              onCancel: _cancelEdit,
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        _StatusBar(
          totalRows: _totalRows,
          loading: _loading,
          editability: widget.summary.editability,
          refusal: _refusal,
          notice: _notice,
          selectedCount: _selected.length,
          onInsert: _insertRow,
          onExport: _export,
          onDeleteSelected: () => _deleteRows(_selected.toList()..sort()),
        ),
      ],
    );
  }
}

class _TruncationBanner extends StatelessWidget {
  const _TruncationBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      // 截断是警告不是错误，要和 errorContainer 的错误横幅分得开，所以用琥珀色，
      // 按比例叠在 surface 上适配深浅两种背景
      color: Color.alphaBlend(Colors.amber.withValues(alpha: 0.3), scheme.surface),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: scheme.onSurface),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '结果已截断：实际行数超过上限，下面显示的不是全部数据。请加 LIMIT 或缩小条件。',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurface),
            ),
          ),
        ],
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
    final mac = MacColors.of(context);
    return Container(
      height: _headerHeight,
      decoration: BoxDecoration(
        color: mac.toolbar,
        border: Border(bottom: BorderSide(color: mac.separator)),
      ),
      child: Row(
        children: [
          Container(
            width: _rowNumberWidth,
            decoration: BoxDecoration(border: Border(right: BorderSide(color: mac.separator))),
          ),
          for (var position = 0; position < order.length; position++)
            _cell(context, mac, position, order[position]),
        ],
      ),
    );
  }

  /// 一个列头：左边拖动换位置、点击排序，右边的窄条拖动改宽度、双击自适应
  Widget _cell(BuildContext context, MacColors mac, int position, int index) {
    final column = columns[index];
    final label = Text(
      column.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _headerStyle.copyWith(color: mac.text),
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
                    height: _headerHeight,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    color: mac.toolbar,
                    child: label,
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.4, child: label),
                child: DecoratedBox(
                  // 拖到这一列上时画左边线，表示会插到这里
                  decoration: BoxDecoration(
                    border: candidates.isEmpty ? null : Border(left: BorderSide(color: mac.accent, width: 2)),
                  ),
                  child: InkWell(
                    onTap: onSortColumn == null ? null : () => onSortColumn!(column.name),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Row(
                        children: [
                          Expanded(child: label),
                          if (sortColumn == column.name)
                            Icon(
                              sortAscending ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                              size: 14,
                              color: mac.secondaryText,
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
              // 竖线贴在列的右边缘，和下面数据格的竖线对齐
              child: SizedBox(
                width: 6,
                height: _headerHeight,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(width: 1, height: _headerHeight, child: ColoredBox(color: mac.separator)),
                ),
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
  final List<DisplayCell>? cells;
  final List<ColumnMeta> columns;
  final List<int> order;
  final List<double> widths;

  /// 这一行里落在选区内的显示位置，null 表示这一行不在选区里
  final ({int left, int right})? selectedPositions;
  final void Function(PointerDownEvent event, int position) onPointerDownCell;
  final void Function(int position, Offset globalPosition) onSecondaryTapCell;
  final int? editingColumn;
  final TextEditingController editController;
  final FocusNode editFocus;
  final void Function(int column) onDoubleTapCell;
  final void Function(String text) onCommit;
  final VoidCallback onSetNull;
  final VoidCallback onCancel;

  const _DataRow({
    required this.rowNumber,
    required this.selected,
    required this.onTapRowNumber,
    required this.cells,
    required this.columns,
    required this.order,
    required this.widths,
    required this.selectedPositions,
    required this.onPointerDownCell,
    required this.onSecondaryTapCell,
    required this.editingColumn,
    required this.editController,
    required this.editFocus,
    required this.onDoubleTapCell,
    required this.onCommit,
    required this.onSetNull,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final gridLine = Border(right: BorderSide(color: mac.separator));
    return DecoratedBox(
      // 没有横线，只靠斑马纹分行；点行号选中的整行叠一层浅系统蓝
      decoration: BoxDecoration(
        color: selected
            ? mac.accent.withValues(alpha: 0.16)
            : rowNumber.isEven
            ? mac.zebra
            : null,
      ),
      child: Row(
        children: [
          GestureDetector(
            key: ValueKey('row-number-${rowNumber - 1}'),
            behavior: HitTestBehavior.opaque,
            onTap: onTapRowNumber,
            child: Container(
              width: _rowNumberWidth,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.centerRight,
              decoration: BoxDecoration(border: gridLine),
              // 行号不抢眼：小一号、三级文字色
              child: Text(
                '$rowNumber',
                style: TextStyle(fontSize: 10, color: selected ? mac.accent : mac.tertiaryText),
              ),
            ),
          ),
          for (var position = 0; position < order.length; position++)
            _cell(mac, gridLine, position, order[position]),
        ],
      ),
    );
  }

  Widget _cell(MacColors mac, Border gridLine, int position, int i) {
    final range = selectedPositions;
    final inRange = range != null && position >= range.left && position <= range.right;
    // 数值右对齐，位数一眼能比；只看列元数据，不看值长得像不像数字
    final alignment = columns[i].kind == ColumnKind.number ? Alignment.centerRight : Alignment.centerLeft;

    return DecoratedBox(
      // 列之间 1px 竖线。画在前景，选区的底色不会盖住它
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(border: gridLine),
      child: SizedBox(
        // 行号列和数据列可能显示一样的文本，测试要靠 key 才能精确定位。
        // i 是结果集里的原始列下标，和显示顺序无关
        key: ValueKey('cell-${rowNumber - 1}-$i'),
        width: widths[i],
        child: editingColumn == i
            ? _CellEditor(
                controller: editController,
                focusNode: editFocus,
                onCommit: onCommit,
                onSetNull: onSetNull,
                onCancel: onCancel,
              )
            // 按下就选中。用 Listener 而不是 onTap：onTap 要等双击判定超时才触发，点了会慢半拍
            : Listener(
                onPointerDown: (event) {
                  if (event.buttons == kPrimaryButton) onPointerDownCell(event, position);
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () => onDoubleTapCell(i),
                  onSecondaryTapUp: (details) => onSecondaryTapCell(position, details.globalPosition),
                  child: ColoredBox(
                    color: inRange ? mac.accent.withValues(alpha: 0.24) : Colors.transparent,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Align(alignment: alignment, child: _CellText(cell: cells?[i])),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// 单元格编辑框。Enter 提交，Esc 取消，∅ 写 NULL。
///
/// NULL 要有独立入口：清空输入提交的是空字符串，和 NULL 是两回事，不能靠猜。
class _CellEditor extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(String text) onCommit;
  final VoidCallback onSetNull;
  final VoidCallback onCancel;

  const _CellEditor({
    required this.controller,
    required this.focusNode,
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
            // 边框和焦点环沿用主题。紧凑输入框高 10 + 上下内边距，5 正好填满 20px 的行
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              style: _cellStyle,
              decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 5)),
              onSubmitted: onCommit,
            ),
          ),
        ),
        Tooltip(
          message: '写入 NULL',
          child: InkWell(
            onTap: onSetNull,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('∅', style: TextStyle(fontSize: 12, color: MacColors.of(context).secondaryText)),
            ),
          ),
        ),
      ],
    );
  }
}

/// NULL 和占位内容要看得出来和普通文本不同，否则分不清「空值」和「空字符串」
class _CellText extends StatelessWidget {
  /// null 表示这一行还没取回来
  final DisplayCell? cell;

  const _CellText({required this.cell});

  @override
  Widget build(BuildContext context) {
    final cell = this.cell;
    if (cell == null) {
      return const Text('', style: _cellStyle);
    }

    final isPlaceholder = cell.placeholder;
    return Text(
      cell.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _cellStyle.copyWith(
        // 不用 onSurfaceVariant：它和 onSurface 太接近，占位和真实文本会分不开。
        // 按 onSurface 的 38% 取色，深浅两种主题同比例变淡；再加斜体
        color: isPlaceholder ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38) : null,
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
  final String? notice;
  final int selectedCount;
  final VoidCallback onInsert;
  final VoidCallback onDeleteSelected;
  final VoidCallback onExport;

  const _StatusBar({
    required this.totalRows,
    required this.loading,
    required this.editability,
    required this.refusal,
    required this.notice,
    required this.selectedCount,
    required this.onInsert,
    required this.onDeleteSelected,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final readOnlyReason = switch (editability) {
      Editability_ReadOnly(:final field0) => field0,
      Editability_Editable() => null,
    };
    final message = refusal ?? notice ?? readOnlyReason;
    final scheme = Theme.of(context).colorScheme;

    return MacStatusBar(
      children: [
        Text('$totalRows 行'),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            message ?? '双击或 Enter 编辑，拖动或 Shift+方向键选区域后可复制粘贴，点行号选中行',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: refusal != null
                  ? scheme.error
                  : message != null
                  ? scheme.onSurfaceVariant
                  : scheme.outline,
            ),
          ),
        ),
        // 刻意不用 CircularProgressIndicator：它是无限动画，会让 pumpAndSettle
        // 永远等不到"稳定"，测试直接挂死。静态文字一样能表达状态
        if (loading) const Text('加载中…'),
        _BarButton(icon: Icons.ios_share, label: '导出', onPressed: onExport),
        // 只读结果集不给增删入口，原因已经显示在左边
        if (readOnlyReason == null) ...[
          if (selectedCount > 0)
            _BarButton(
              icon: Icons.remove,
              label: '删除 $selectedCount 行',
              color: scheme.error,
              onPressed: onDeleteSelected,
            ),
          _BarButton(icon: Icons.add, label: '新增行', onPressed: onInsert),
        ],
      ],
    );
  }
}

/// 状态栏里的小按钮：18px 高、11pt 字，放得进 22px 的状态栏
class _BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onPressed;

  const _BarButton({required this.icon, required this.label, required this.onPressed, this.color});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 18),
        iconSize: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      // 字号写在 Text 上而不是 textStyle：textStyle 会整个替换主题的按钮字体
      label: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }
}
