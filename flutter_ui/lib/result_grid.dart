import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show DragStartBehavior, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data_source.dart';
import 'package:file_selector/file_selector.dart' show XTypeGroup, getSaveLocation;

import 'cell_editors.dart';
import 'export_dialog.dart';
import 'insert_row_dialog.dart';
import 'src/rust/api/db.dart';
import 'src/rust/api/layouts.dart';
import 'src/rust/api/value.dart';

Future<String?> _systemSavePath(String suggestedName) async {
  final extension = suggestedName.split('.').last;
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: [XTypeGroup(label: extension.toUpperCase(), extensions: [extension])],
  );
  return location?.path;
}

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

  /// 选导出文件的保存位置，返回 null 表示取消。不传就弹系统保存对话框，测试里换掉
  final Future<String?> Function(String suggestedName)? pickSavePath;

  const ResultGrid({
    super.key,
    required this.source,
    this.onSortColumn,
    this.sortColumn,
    this.sortAscending = true,
    this.pickSavePath,
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

  /// 网格本身的焦点。复制粘贴快捷键只在它拿着焦点时接管，编辑框里的 ⌘C 归编辑框
  final _gridFocus = FocusNode(debugLabel: 'result-grid');

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
    _gridFocus.dispose();
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
    const headerStyle = TextStyle(fontWeight: FontWeight.w600, fontSize: 12);
    const cellStyle = TextStyle(fontSize: 12, fontFamily: 'Menlo');

    // 表头右边还要留出排序箭头（12）和拖拽柄（6）
    var widest = _textWidth(widget.summary.columns[column].name, headerStyle) + 18;
    // ponytail: 只量当前窗口（最多 200 行），不为了自适应去扫整个结果集
    for (final row in _windowRows) {
      widest = math.max(widest, _textWidth(row[column].text, cellStyle));
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
      case ColumnKind.text:
      case ColumnKind.number:
      case ColumnKind.time:
        _editController.text = current ?? '';
        _startInlineEdit(rowIndex, columnIndex);
        return;
    }

    if (value != null) await _writeCell(rowIndex, columnIndex, value);
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
    await _writeCell(editing.row, editing.column, newValue);
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

  void _selectCell(int row, int position) {
    _gridFocus.requestFocus();
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

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // 编辑框拿着焦点时事件也会冒泡到这里，那时的 ⌘C / ⌘V 归编辑框
    if (!node.hasPrimaryFocus || event is! KeyDownEvent) return KeyEventResult.ignored;

    // macOS 用 ⌘，Windows 用 Ctrl，两个都认
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isMetaPressed && !keyboard.isControlPressed) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      _copySelection();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      _pasteFromClipboard();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 复制选区。编码在 Rust 侧做，NULL、二进制、带制表符的文本怎么写都在那里定
  Future<void> _copySelection() async {
    final range = _range;
    if (range == null) return;

    final rowCount = range.bottom - range.top + 1;
    final columns = _order.sublist(range.left, range.right + 1);
    try {
      final tsv = await widget.source.copyRange(range.top, rowCount, columns);
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
        title: Text('粘贴 $rowCount 行 × $columnCount 列？', style: const TextStyle(fontSize: 16)),
        content: Text(
          '从第 ${range.top + 1} 行的 $firstColumn 列开始覆盖，直接写入数据库，不能撤销。\n'
          '所有格子在一个事务里写入，任何一格没写成都会整体回滚。\n'
          '不带引号的 NULL 写成 NULL，空格子写成空字符串。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
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
                          final range = _range;
                          return _DataRow(
                            selectedPositions:
                                range != null && index >= range.top && index <= range.bottom
                                ? (left: range.left, right: range.right)
                                : null,
                            onPointerDownCell: (position) => _selectCell(index, position),
                            rowNumber: index + 1,
                            selected: _selected.contains(index),
                            onTapRowNumber: () => _toggleSelected(index),
                            cells: cells,
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      // 截断是警告不是错误，要和 errorContainer 的错误横幅分得开；这套 seed 的 tertiaryContainer
      // 是粉色，浅色下和 errorContainer 几乎一样，所以沿用琥珀色，按比例叠在 surface 上适配深浅两种背景
      color: Color.alphaBlend(Colors.amber.withValues(alpha: 0.3), scheme.surface),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        '结果已截断：实际行数超过上限，下面显示的不是全部数据。请加 LIMIT 或缩小条件。',
        style: TextStyle(fontSize: 12, color: scheme.onSurface),
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
        border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outline)),
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
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
              child: SizedBox(
                width: 6,
                height: 32,
                child: Center(
                  child: SizedBox(
                    width: 1,
                    height: 16,
                    child: ColoredBox(color: Theme.of(context).colorScheme.outline),
                  ),
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
  final List<int> order;
  final List<double> widths;

  /// 这一行里落在选区内的显示位置，null 表示这一行不在选区里
  final ({int left, int right})? selectedPositions;
  final void Function(int position) onPointerDownCell;
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
    required this.order,
    required this.widths,
    required this.selectedPositions,
    required this.onPointerDownCell,
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
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : rowNumber.isEven
            ? scheme.onSurface.withValues(alpha: 0.02)
            : null,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
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
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
          for (var position = 0; position < order.length; position++)
            _cell(context, position, order[position]),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, int position, int i) {
    final range = selectedPositions;
    final inRange = range != null && position >= range.left && position <= range.right;

    return SizedBox(
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
                if (event.buttons == kPrimaryButton) onPointerDownCell(position);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => onDoubleTapCell(i),
                child: ColoredBox(
                  color: inRange
                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18)
                      : Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _CellText(cell: cells?[i]),
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
            child: TextField(
              controller: controller,
              focusNode: focusNode,
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '∅',
                style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
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
      return const Text('', style: TextStyle(fontSize: 12));
    }

    final isPlaceholder = cell.placeholder;
    return Text(
      cell.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontFamily: 'Menlo',
        // 不用 onSurfaceVariant：它和 onSurface 太接近，占位和真实文本会分不开。
        // 按 onSurface 的 38% 取色，浅色下和原来的 black38 一样淡，深色下同比例变暗
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

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: scheme.outline)),
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
                  color: refusal != null ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Expanded(
              child: Text(
                '双击编辑，Shift 点选区域后可复制粘贴，点行号选中行',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
            ),
          // 刻意不用 CircularProgressIndicator：它是无限动画，会让 pumpAndSettle
          // 永远等不到"稳定"，测试直接挂死。静态文字一样能表达状态
          if (loading) Text('加载中…', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          _BarButton(label: '导出', onPressed: onExport),
          // 只读结果集不给增删入口，原因已经显示在左边
          if (readOnlyReason == null) ...[
            if (selectedCount > 0)
              _BarButton(
                label: '删除 $selectedCount 行',
                color: scheme.error,
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
