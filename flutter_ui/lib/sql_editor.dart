import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter/services.dart';

import 'src/rust/api/editor.dart';

/// 词法切分函数。生产环境是 Rust 的 tokenizeSql，测试里换成假的
typedef SqlTokenizer = List<SqlToken> Function(String sql);

/// 带语法高亮的 SQL 输入框控制器。切 token 在 Rust 侧做，这里只按 token 上色
class SqlEditingController extends TextEditingController {
  final SqlTokenizer tokenize;

  SqlEditingController({required this.tokenize, super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 输入法正在组词时不高亮：组词区的下划线由默认实现画，自己拆 span 会把它弄丢，中文输入会乱
    if (withComposing && value.composing.isValid && !value.composing.isCollapsed) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }

    final text = value.text;
    final spans = <TextSpan>[];
    var position = 0;
    for (final token in tokenize(text)) {
      if (token.start > position) spans.add(TextSpan(text: text.substring(position, token.start)));
      spans.add(
        TextSpan(text: text.substring(token.start, token.end), style: tokenStyle(token.kind)),
      );
      position = token.end;
    }
    if (position < text.length) spans.add(TextSpan(text: text.substring(position)));

    return TextSpan(style: style, children: spans);
  }
}

/// 各类 token 的颜色。普通标识符、运算符、标点不上色
TextStyle? tokenStyle(SqlTokenKind kind) {
  return switch (kind) {
    SqlTokenKind.keyword => const TextStyle(color: Color(0xFF3949AB), fontWeight: FontWeight.w600),
    SqlTokenKind.string => const TextStyle(color: Color(0xFF2E7D32)),
    SqlTokenKind.number => const TextStyle(color: Color(0xFFE65100)),
    SqlTokenKind.comment => const TextStyle(color: Color(0xFF9E9E9E), fontStyle: FontStyle.italic),
    SqlTokenKind.quotedIdentifier => const TextStyle(color: Color(0xFF00796B)),
    SqlTokenKind.variable => const TextStyle(color: Color(0xFF7B1FA2)),
    SqlTokenKind.identifier || SqlTokenKind.operator_ || SqlTokenKind.punctuation => null,
  };
}

/// 补全函数：给 SQL 和光标（UTF-16 下标）返回候选。返回 null 表示现在补不了（比如还没连上库）
typedef SqlCompleter = Completion? Function(String sql, int cursor);

/// SQL 编辑框：高亮 + 补全弹窗 + ⌘ / Ctrl + Enter 运行。
///
/// 打字时光标前是标识符字符或点就弹候选；上下键选，Enter / Tab 接受，Esc 关掉，
/// Ctrl + Space 手动唤出。候选怎么算由 Rust 侧决定，这里只管显示和替换文本。
class SqlEditorField extends StatefulWidget {
  final SqlEditingController controller;
  final SqlCompleter? complete;
  final VoidCallback? onRun;

  const SqlEditorField({
    super.key,
    required this.controller,
    required this.complete,
    required this.onRun,
  });

  @override
  State<SqlEditorField> createState() => _SqlEditorFieldState();
}

class _SqlEditorFieldState extends State<SqlEditorField> {
  static const double _itemHeight = 24;
  static const int _visibleItems = 8;

  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _fieldKey = GlobalKey();
  final _listScroll = ScrollController();

  Completion? _completion;
  int _selected = 0;

  /// 弹窗左上角相对编辑框的位置：光标那一行的下方
  Offset _popupOffset = Offset.zero;

  /// 接受候选时改文本会再触发一次监听，不能又弹出来
  bool _applying = false;
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _lastText = widget.controller.text;
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _listScroll.dispose();
    super.dispose();
  }

  bool get _open => _completion != null;

  void _onChanged() {
    final text = widget.controller.text;
    final textChanged = text != _lastText;
    _lastText = text;
    if (_applying) return;

    final selection = widget.controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _close();
      return;
    }
    if (!textChanged) {
      // 只挪了光标：挪出了正在补全的那个词就关掉
      final completion = _completion;
      final cursor = selection.baseOffset;
      if (completion != null &&
          (cursor < completion.replaceStart || cursor > completion.replaceEnd + 1)) {
        _close();
      }
      return;
    }

    final cursor = selection.baseOffset;
    final previous = cursor > 0 ? text[cursor - 1] : '';
    final typingName =
        previous == '.' ||
        previous == '`' ||
        RegExp(r'[\p{L}\p{N}_$]', unicode: true).hasMatch(previous);
    if (typingName) {
      _refresh();
    } else {
      _close();
    }
  }

  void _refresh() {
    final complete = widget.complete;
    final selection = widget.controller.selection;
    if (complete == null || !selection.isValid || !selection.isCollapsed) return;

    final completion = complete(widget.controller.text, selection.baseOffset);
    if (completion == null || completion.items.isEmpty) {
      _close();
      return;
    }
    setState(() {
      _completion = completion;
      _selected = 0;
    });
    _portal.show();
    // 文本这一帧才重新排版，排完再量光标位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_open) return;
      setState(() => _popupOffset = _caretOffset(selection.baseOffset));
      if (_listScroll.hasClients) _listScroll.jumpTo(0);
    });
  }

  void _close() {
    if (!_open) return;
    setState(() => _completion = null);
    _portal.hide();
  }

  void _move(int delta) {
    final completion = _completion;
    if (completion == null) return;
    final count = completion.items.length;
    // Dart 的 % 对正数除数总是非负，往上翻过头会绕到最后一项
    setState(() => _selected = (_selected + delta) % count);

    // 选中项滚进可视区
    if (!_listScroll.hasClients) return;
    final top = _selected * _itemHeight;
    final bottom = top + _itemHeight;
    final viewTop = _listScroll.offset;
    final viewBottom = viewTop + _itemHeight * _visibleItems;
    if (top < viewTop) _listScroll.jumpTo(top);
    if (bottom > viewBottom) _listScroll.jumpTo(bottom - _itemHeight * _visibleItems);
  }

  void _accept([int? index]) {
    final completion = _completion;
    if (completion == null) return;
    final item = completion.items[index ?? _selected];

    final text = widget.controller.text;
    final newText = text.replaceRange(
      completion.replaceStart,
      completion.replaceEnd,
      item.insertText,
    );
    final cursor = completion.replaceStart + item.insertText.length;
    _applying = true;
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor),
    );
    _applying = false;
    _close();
  }

  /// 光标底边相对编辑框左上角的位置。找不到排版信息就放在编辑框底下
  Offset _caretOffset(int offset) {
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;

    RenderEditable? editable;
    void visit(RenderObject child) {
      if (editable != null) return;
      if (child is RenderEditable) {
        editable = child;
        return;
      }
      child.visitChildren(visit);
    }

    box.visitChildren(visit);
    final found = editable;
    if (found == null) return Offset(0, box.size.height);
    final caret = found.getLocalRectForCaret(TextPosition(offset: offset));
    return box.globalToLocal(found.localToGlobal(caret.bottomLeft));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final withModifier = keyboard.isMetaPressed || keyboard.isControlPressed;

    if (withModifier && key == LogicalKeyboardKey.enter) {
      _close();
      widget.onRun?.call();
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed && key == LogicalKeyboardKey.space) {
      _refresh();
      return KeyEventResult.handled;
    }
    if (!_open) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.tab) {
      _accept();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        final completion = _completion;
        if (completion == null) return const SizedBox.shrink();
        return CompositedTransformFollower(
          link: _link,
          offset: _popupOffset + const Offset(0, 2),
          showWhenUnlinked: false,
          child: Align(
            alignment: Alignment.topLeft,
            // 点弹窗算点在编辑框里面，否则桌面端点一下编辑框就失焦了
            child: TextFieldTapRegion(
              child: _CompletionList(
                items: completion.items,
                selected: _selected,
                itemHeight: _itemHeight,
                visibleItems: _visibleItems,
                controller: _listScroll,
                onTap: _accept,
              ),
            ),
          ),
        );
      },
      child: CompositedTransformTarget(
        link: _link,
        // 事件先到输入框，输入框不处理才冒泡到这里；弹窗开着时上下键、回车归补全
        child: Focus(
          onKeyEvent: _onKey,
          child: TextField(
            key: _fieldKey,
            controller: widget.controller,
            maxLines: 6,
            minLines: 2,
            style: const TextStyle(fontSize: 13, fontFamily: 'Menlo'),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.all(10),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompletionList extends StatelessWidget {
  final List<CompletionItem> items;
  final int selected;
  final double itemHeight;
  final int visibleItems;
  final ScrollController controller;
  final void Function(int index) onTap;

  const _CompletionList({
    required this.items,
    required this.selected,
    required this.itemHeight,
    required this.visibleItems,
    required this.controller,
    required this.onTap,
  });

  static IconData _icon(CompletionKind kind) {
    return switch (kind) {
      CompletionKind.table => Icons.table_rows_outlined,
      CompletionKind.column => Icons.view_column_outlined,
      CompletionKind.alias => Icons.label_outline,
      CompletionKind.keyword => Icons.key_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final count = items.length < visibleItems ? items.length : visibleItems;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        key: const ValueKey('completion-popup'),
        width: 360,
        height: count * itemHeight,
        child: ListView.builder(
          controller: controller,
          itemExtent: itemHeight,
          padding: EdgeInsets.zero,
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return InkWell(
              onTap: () => onTap(index),
              child: Container(
                color: index == selected ? scheme.primaryContainer : null,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Icon(_icon(item.kind), size: 13, color: Colors.black45),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
                      ),
                    ),
                    Text(item.detail, style: const TextStyle(fontSize: 11, color: Colors.black38)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
