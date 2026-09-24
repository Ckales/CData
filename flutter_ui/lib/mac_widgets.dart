// Querious / macOS 风格的通用控件。颜色都取自 MacColors 和 colorScheme，不写死。
//
// 只放跨页面复用的外观件：工具栏、工具栏按钮、侧栏行、搜索框、标签条、状态栏、窗口拖动区。
// 业务逻辑不进这里。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

/// macOS 上红绿灯浮在工具栏左边，要给它们让出位置。Windows 用系统标题栏，不用让
double get trafficLightInset => _isMac ? 78 : 0;

const _windowChannel = MethodChannel('cdata/window');

/// 工具栏空白处：按住拖动窗口，双击缩放。只在 macOS 上有意义（标题栏被内容盖住了）
class WindowDragArea extends StatelessWidget {
  final Widget child;

  const WindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!_isMac) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => _windowChannel.invokeMethod<void>('startDrag'),
      onDoubleTap: () => _windowChannel.invokeMethod<void>('titleDoubleClick'),
      child: child,
    );
  }
}

/// 窗口顶部的工具栏：和标题栏合成一条，52px 高
class MacToolbar extends StatelessWidget {
  final List<Widget> children;

  const MacToolbar({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    return WindowDragArea(
      child: Container(
        height: 52,
        padding: EdgeInsets.only(left: 12 + trafficLightInset, right: 12),
        decoration: BoxDecoration(
          color: mac.toolbar,
          border: Border(bottom: BorderSide(color: mac.separator)),
        ),
        child: Row(children: children),
      ),
    );
  }
}

/// 工具栏上的图标按钮。selected 时有一块浅色底，表示当前模式
class ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback? onPressed;

  const ToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.selected = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Material(
          color: selected ? mac.text.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: SizedBox(
              width: 36,
              height: 28,
              child: Icon(
                icon,
                size: 18,
                color: !enabled
                    ? mac.tertiaryText.withValues(alpha: 0.5)
                    : selected
                    ? mac.accent
                    : mac.secondaryText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 工具栏里的竖分隔
class ToolbarDivider extends StatelessWidget {
  const ToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: MacColors.of(context).separator,
    );
  }
}

/// 侧栏的一行：图标 + 名字 + 右侧小字。选中时整行系统蓝、白字
class SidebarItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? trailing;
  final bool selected;
  final VoidCallback? onTap;
  final void Function(Offset position)? onSecondaryTap;
  final double indent;

  const SidebarItem({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.label,
    this.trailing,
    this.selected = false,
    this.onTap,
    this.onSecondaryTap,
    this.indent = 0,
  });

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final foreground = selected ? Colors.white : mac.text;
    final secondaryTap = onSecondaryTap;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: GestureDetector(
        onSecondaryTapUp: secondaryTap == null ? null : (details) => secondaryTap(details.globalPosition),
        child: Material(
          color: selected ? mac.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          child: InkWell(
            borderRadius: BorderRadius.circular(5),
            onTap: onTap,
            child: Container(
              height: 24,
              padding: EdgeInsets.only(left: 6 + indent, right: 8),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: selected ? Colors.white : iconColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: foreground),
                    ),
                  ),
                  if (trailing != null)
                    Text(
                      trailing!,
                      style: TextStyle(fontSize: 11, color: selected ? Colors.white70 : mac.tertiaryText),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆角搜索框：左边放大镜，有内容时右边一个清除按钮
class MacSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final IconData icon;

  const MacSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.icon = Icons.search,
  });

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    return SizedBox(
      height: 26,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => TextField(
          controller: controller,
          onChanged: onChanged,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, size: 15, color: mac.tertiaryText),
            prefixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 24),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除',
                    icon: Icon(Icons.cancel, size: 14, color: mac.tertiaryText),
                    onPressed: () {
                      controller.clear();
                      onChanged?.call('');
                    },
                  ),
            suffixIconConstraints: const BoxConstraints(minWidth: 26, minHeight: 24),
            contentPadding: const EdgeInsets.symmetric(vertical: 5),
            fillColor: mac.text.withValues(alpha: 0.06),
            enabledBorder: OutlineInputBorder(
              borderRadius: const BorderRadius.all(Radius.circular(6)),
              borderSide: BorderSide(color: mac.separator),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一个标签
class MacTab {
  final Key key;
  final String title;
  final String? tooltip;

  const MacTab({required this.key, required this.title, this.tooltip});
}

/// 等宽的标签条（Safari / Querious 那种）：灰底，当前标签浅色，关闭按钮在标签左边
class MacTabStrip extends StatelessWidget {
  final List<MacTab> tabs;
  final int active;
  final void Function(int index) onSelect;
  final void Function(int index) onClose;
  final VoidCallback onAdd;
  final String addTooltip;

  const MacTabStrip({
    super.key,
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
    required this.addTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: mac.toolbar,
        border: Border(bottom: BorderSide(color: mac.separator)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: _TabCell(
                tab: tabs[i],
                selected: i == active,
                // 只有一个标签时不给关，关了就只剩空白
                onClose: tabs.length > 1 ? () => onClose(i) : null,
                onTap: () => onSelect(i),
              ),
            ),
          Tooltip(
            message: addTooltip,
            child: InkWell(
              onTap: onAdd,
              child: SizedBox(width: 28, height: 26, child: Icon(Icons.add, size: 14, color: mac.secondaryText)),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabCell extends StatefulWidget {
  final MacTab tab;
  final bool selected;
  final VoidCallback? onClose;
  final VoidCallback onTap;

  const _TabCell({required this.tab, required this.selected, required this.onClose, required this.onTap});

  @override
  State<_TabCell> createState() => _TabCellState();
}

class _TabCellState extends State<_TabCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final onClose = widget.onClose;
    final cell = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        key: widget.tab.key,
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: widget.selected ? mac.window : Colors.transparent,
            border: Border(right: BorderSide(color: mac.separator)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: onClose != null && (_hover || widget.selected)
                    ? InkWell(
                        onTap: onClose,
                        borderRadius: BorderRadius.circular(3),
                        child: Tooltip(
                          message: '关闭标签',
                          child: Icon(Icons.close, size: 12, color: mac.secondaryText),
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: Text(
                  widget.tab.title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.selected ? mac.text : mac.secondaryText,
                    fontWeight: widget.selected ? FontWeight.w500 : null,
                  ),
                ),
              ),
              const SizedBox(width: 18),
            ],
          ),
        ),
      ),
    );
    final tooltip = widget.tab.tooltip;
    if (tooltip == null) return cell;
    return Tooltip(message: tooltip, waitDuration: const Duration(milliseconds: 700), child: cell);
  }
}

/// 窗口底部的状态栏，22px 高
class MacStatusBar extends StatelessWidget {
  final List<Widget> children;

  const MacStatusBar({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: mac.toolbar,
        border: Border(top: BorderSide(color: mac.separator)),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 11, color: mac.secondaryText),
        child: Row(children: children),
      ),
    );
  }
}

/// 表单的一行：左边右对齐的标签，右边控件。macOS 偏好设置、连接表单都是这种排法
class FormRow extends StatelessWidget {
  final String label;
  final Widget child;
  final double labelWidth;

  const FormRow({super.key, required this.label, required this.child, this.labelWidth = 110});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              '$label：',
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// macOS 的弹出按钮（NSPopUpButton）：白底细边框、右侧上下箭头，点开是一列紧凑的菜单项，当前项打勾。
///
/// 不用 DropdownButton：它的菜单项被断言成至少 48px 高，做不出 Mac 那种紧凑的菜单。
/// 当前值不在选项里（比如列选择器里那一列被删了）时显示 placeholder，不拿原始值冒充显示文字
class MacPopupButton<T> extends StatelessWidget {
  final T value;

  /// 选项和显示文字，按插入顺序排
  final Map<T, String> items;

  /// null 表示整个按钮不可用
  final ValueChanged<T>? onChanged;

  /// 列出来但不能选的项
  final Set<T> disabled;

  /// 撑满父级宽度；否则按内容定宽
  final bool expand;

  final String placeholder;

  const MacPopupButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.disabled = const {},
    this.expand = false,
    this.placeholder = '—',
  });

  @override
  Widget build(BuildContext context) {
    final mac = MacColors.of(context);
    final enabled = onChanged != null;
    final label = items[value];
    final text = Text(
      label ?? placeholder,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: enabled && label != null ? mac.text : mac.tertiaryText),
    );
    return PopupMenuButton<T>(
      initialValue: value,
      enabled: enabled,
      // 空串就不挂 Tooltip，否则悬停会冒出 Material 的「Show menu」
      tooltip: '',
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final entry in items.entries)
          PopupMenuItem<T>(
            value: entry.key,
            height: 24,
            enabled: !disabled.contains(entry.key),
            padding: const EdgeInsets.only(left: 4, right: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  child: entry.key == value ? Icon(Icons.check, size: 13, color: mac.text) : null,
                ),
                Flexible(child: Text(entry.value, style: const TextStyle(fontSize: 13))),
              ],
            ),
          ),
      ],
      child: Container(
        height: 22,
        padding: const EdgeInsets.only(left: 8, right: 4),
        decoration: BoxDecoration(
          color: enabled ? mac.control : mac.window,
          border: Border.all(color: enabled ? mac.controlBorder : mac.separator),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (expand) Expanded(child: text) else Flexible(child: text),
            const SizedBox(width: 4),
            Icon(Icons.unfold_more, size: 14, color: enabled ? mac.secondaryText : mac.tertiaryText),
          ],
        ),
      ),
    );
  }
}

/// 面板顶上的一条细工具栏：窗口灰底、底部一条分隔线，放分页和操作按钮。
///
/// 只用 colorScheme（appTheme 里 surfaceContainer 就是窗口灰），没套 appTheme 的测试里也能用
class MacPanelBar extends StatelessWidget {
  final List<Widget> children;

  const MacPanelBar({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(children: children),
    );
  }
}

/// 分页标签：选中项一块浅灰圆角底，像 Xcode / Querious 的分段切换，不用 Material 的下划线。
/// 要放在 DefaultTabController 里面。和 MacPanelBar 一样只用 colorScheme
class MacTabBar extends StatelessWidget {
  final List<String> labels;

  const MacTabBar({super.key, required this.labels});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TabBar(
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      dividerHeight: 0,
      padding: EdgeInsets.zero,
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: BoxDecoration(color: scheme.onSurface.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(5)),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
      labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 12),
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
      tabs: [
        for (final label in labels)
          Tab(
            height: 22,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(label)),
          ),
      ],
    );
  }
}
