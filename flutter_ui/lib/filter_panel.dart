import 'package:flutter/material.dart';

import 'mac_widgets.dart';
import 'src/rust/api/db.dart';
import 'theme.dart';

/// 运算符在界面上的写法
String filterOpLabel(FilterOp op) {
  return switch (op) {
    FilterOp.eq => '=',
    FilterOp.notEq => '≠',
    FilterOp.lt => '<',
    FilterOp.ltEq => '≤',
    FilterOp.gt => '>',
    FilterOp.gtEq => '≥',
    FilterOp.contains => '包含',
    FilterOp.notContains => '不包含',
    FilterOp.startsWith => '开头是',
    FilterOp.endsWith => '结尾是',
    FilterOp.isNull => '为 NULL',
    FilterOp.isNotNull => '不为 NULL',
    FilterOp.in_ => '属于列表',
    FilterOp.notIn => '不属于列表',
  };
}

/// IS NULL 这类运算符不看值
bool filterOpTakesValue(FilterOp op) => op != FilterOp.isNull && op != FilterOp.isNotNull;

/// IN / NOT IN 的值是一行一个的列表，怎么切、哪些值不许写由 core 定
bool filterOpTakesList(FilterOp op) => op == FilterOp.in_ || op == FilterOp.notIn;

String _describeCondition(FilterCondition condition) {
  final op = filterOpLabel(condition.op);
  if (!filterOpTakesValue(condition.op)) return '${condition.column} $op';
  if (filterOpTakesList(condition.op)) {
    // 只是摘要：换行显示成逗号，末尾粘贴带进来的换行不显示
    final lines = condition.value.replaceAll('\r\n', '\n');
    final shown = lines.endsWith('\n') ? lines.substring(0, lines.length - 1) : lines;
    return '${condition.column} $op (${shown.replaceAll('\n', ', ')})';
  }
  return '${condition.column} $op ${condition.value}';
}

/// 分组筛选的描述，里层的组加括号：「(a = 1 且 b = 2) 或 c 为 NULL」
String describeFilterGroup(FilterGroup group) {
  final parts = <String>[];
  for (final item in group.items) {
    parts.add(switch (item) {
      FilterItem_Condition(:final field0) => _describeCondition(field0),
      FilterItem_Group(:final field0) => '(${describeFilterGroup(field0)})',
    });
  }
  return parts.join(group.matchAll ? ' 且 ' : ' 或 ');
}

/// 结果上方的筛选条：当前条件的摘要 + 编辑 / 清除入口
class FilterBar extends StatelessWidget {
  /// 当前筛选的摘要，null 表示没有筛选
  final String? description;
  final VoidCallback? onEdit;
  final VoidCallback? onClear;

  FilterBar({
    super.key,
    required FilterGroup filter,
    required this.onEdit,
    required this.onClear,
  }) : description = filter.items.isEmpty ? null : describeFilterGroup(filter);

  @override
  Widget build(BuildContext context) {
    final description = this.description;
    final mac = MacColors.of(context);
    // Querious 网格上方那一条：左边一个小弹出按钮，后面接当前条件
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: mac.window,
        border: Border(bottom: BorderSide(color: mac.separator)),
      ),
      child: Row(
        children: [
          OutlinedButton(
            onPressed: onEdit,
            // 高度跟主题按钮一样 24px：带边框的按钮再矮，边框就贴着字了
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.only(left: 6, right: 2, top: 4, bottom: 4),
              // 有筛选时按钮变成系统蓝，一眼看出结果是筛过的
              foregroundColor: description == null ? mac.text : mac.accent,
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.filter_alt_outlined, size: 13),
                SizedBox(width: 3),
                // 字号写在 Text 上而不是 textStyle：textStyle 会整个替换主题的按钮字体
                Text('筛选', style: TextStyle(fontSize: 12)),
                Icon(Icons.unfold_more, size: 13),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              description ?? '未筛选',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: description == null ? mac.tertiaryText : mac.text),
            ),
          ),
          if (description != null)
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 22),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              ),
              child: const Text('清除', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

/// 编辑分组筛选，组里可以再套组。取消返回 null，最外层一条都不留就是清除筛选
Future<FilterGroup?> showFilterGroupDialog(
  BuildContext context, {
  required List<String> columns,
  required FilterGroup initial,
}) {
  return showDialog<FilterGroup>(
    context: context,
    builder: (context) => _FilterDialog(columns: columns, initial: initial),
  );
}

/// 编辑中的一个节点：一条条件或一个分组
sealed class _Node {}

class _Draft extends _Node {
  String column;
  FilterOp op;
  final TextEditingController value;

  _Draft({required this.column, required this.op, required String value})
      : value = TextEditingController(text: value);
}

class _GroupDraft extends _Node {
  bool matchAll;
  final List<_Node> items = [];

  _GroupDraft({required this.matchAll});
}

class _FilterDialog extends StatefulWidget {
  final List<String> columns;
  final FilterGroup initial;

  /// 单层筛选的调用方收不了分组，不给「添加分组」

  const _FilterDialog({required this.columns, required this.initial});

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  late final _GroupDraft _root = _draftOf(widget.initial);

  @override
  void initState() {
    super.initState();
    // 第一次打开给一条空的，省得再点「添加条件」
    if (_root.items.isEmpty) _root.items.add(_newDraft());
  }

  @override
  void dispose() {
    _disposeNode(_root);
    super.dispose();
  }

  _GroupDraft _draftOf(FilterGroup group) {
    final draft = _GroupDraft(matchAll: group.matchAll);
    for (final item in group.items) {
      draft.items.add(switch (item) {
        FilterItem_Condition(:final field0) =>
          _Draft(column: field0.column, op: field0.op, value: field0.value),
        FilterItem_Group(:final field0) => _draftOf(field0),
      });
    }
    return draft;
  }

  void _disposeNode(_Node node) {
    switch (node) {
      case _Draft():
        node.value.dispose();
      case _GroupDraft():
        for (final item in node.items) {
          _disposeNode(item);
        }
    }
  }

  _Draft _newDraft() => _Draft(column: widget.columns.first, op: FilterOp.eq, value: '');

  /// 删掉 group 里的第 index 项。里层的组删空了就连组一起删：空组在 core 里是拒绝的，
  /// 留着只会让「应用」报错
  void _remove(List<_GroupDraft> path, int index) {
    setState(() {
      _disposeNode(path.last.items.removeAt(index));
      for (var level = path.length - 1; level > 0; level--) {
        final group = path[level];
        if (group.items.isNotEmpty) break;
        path[level - 1].items.remove(group);
      }
    });
  }

  FilterGroup _groupOf(_GroupDraft draft) {
    final items = <FilterItem>[];
    for (final node in draft.items) {
      switch (node) {
        case _Draft():
          items.add(FilterItem.condition(FilterCondition(
            column: node.column,
            op: node.op,
            // 不看值的运算符不带值，免得描述里出现残留的旧输入
            value: filterOpTakesValue(node.op) ? node.value.text : '',
          )));
        case _GroupDraft():
          items.add(FilterItem.group(_groupOf(node)));
      }
    }
    return FilterGroup(matchAll: draft.matchAll, items: items);
  }

  void _apply() => Navigator.of(context).pop(_groupOf(_root));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Text('筛选'),
          const Spacer(),
          _matchDropdown(_root, const ValueKey('filter-match')),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _groupBody([_root], ''),
          ),
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _apply, child: const Text('应用')),
      ],
    );
  }

  Widget _matchDropdown(_GroupDraft group, Key key) {
    return MacPopupButton<bool>(
      key: key,
      value: group.matchAll,
      items: const {true: '满足全部条件', false: '满足任一条件'},
      onChanged: (value) => setState(() => group.matchAll = value),
    );
  }

  /// 小号的文字按钮：添加条件、添加分组
  Widget _smallButton(Key key, IconData icon, String label, VoidCallback onPressed) {
    return TextButton.icon(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 22),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        iconSize: 14,
      ),
      icon: Icon(icon),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  /// 删掉一条或一个分组的小叉
  Widget _removeButton(Key key, String tooltip, VoidCallback onPressed) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      style: IconButton.styleFrom(minimumSize: const Size(22, 22), padding: EdgeInsets.zero, iconSize: 14),
      onPressed: onPressed,
      icon: const Icon(Icons.remove_circle_outline),
    );
  }

  /// 一个组里的各项和底部的添加按钮。path 是从最外层到这个组的链；
  /// key 用下标路径，最外层是 `0`、`1`，第 1 项里的第 0 项是 `1.0`
  List<Widget> _groupBody(List<_GroupDraft> path, String keyPrefix) {
    final group = path.last;
    final addSuffix = keyPrefix.isEmpty ? '' : '-${keyPrefix.substring(0, keyPrefix.length - 1)}';
    return [
      for (var i = 0; i < group.items.length; i++)
        switch (group.items[i]) {
          final _Draft draft => _draftRow(draft, path, i, '$keyPrefix$i'),
          final _GroupDraft inner => _groupBox(inner, path, i, '$keyPrefix$i'),
        },
      Row(
        children: [
          _smallButton(
            ValueKey('filter-add$addSuffix'),
            Icons.add,
            '添加条件',
            () => setState(() => group.items.add(_newDraft())),
          ),
          _smallButton(
            ValueKey('filter-add-group$addSuffix'),
            Icons.account_tree_outlined,
            '添加分组',
            // 新组先给一条条件：空组没有意义，core 也不收
            () => setState(() => group.items.add(_GroupDraft(matchAll: !group.matchAll)..items.add(_newDraft()))),
          ),
        ],
      ),
    ];
  }

  Widget _groupBox(_GroupDraft inner, List<_GroupDraft> path, int index, String key) {
    final mac = MacColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 2),
      // 分组是一块浅底带细边框的区域，像 macOS 的分组框
      decoration: BoxDecoration(
        color: mac.text.withValues(alpha: 0.03),
        border: Border.all(color: mac.separator),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('分组', style: TextStyle(fontSize: 12, color: mac.secondaryText)),
              const SizedBox(width: 8),
              _matchDropdown(inner, ValueKey('filter-match-$key')),
              const Spacer(),
              _removeButton(ValueKey('filter-remove-$key'), '删掉这个分组', () => _remove(path, index)),
            ],
          ),
          ..._groupBody([...path, inner], '$key.'),
        ],
      ),
    );
  }

  Widget _draftRow(_Draft draft, List<_GroupDraft> path, int index, String key) {
    // 条件里的列不在当前列里时也列出来，让人看得见、能改掉，而不是让下拉框直接崩
    final columns = [...widget.columns];
    if (!columns.contains(draft.column)) columns.add(draft.column);
    final takesList = filterOpTakesList(draft.op);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: MacPopupButton<String>(
              key: ValueKey('filter-column-$key'),
              value: draft.column,
              items: {for (final column in columns) column: column},
              onChanged: (column) => setState(() => draft.column = column),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 100,
            child: MacPopupButton<FilterOp>(
              key: ValueKey('filter-op-$key'),
              value: draft.op,
              items: {for (final op in FilterOp.values) op: filterOpLabel(op)},
              onChanged: (op) => setState(() => draft.op = op),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              key: ValueKey('filter-value-$key'),
              controller: draft.value,
              enabled: filterOpTakesValue(draft.op),
              // 列表一行一个值，回车是换行；单值时回车直接应用
              minLines: 1,
              maxLines: takesList ? 5 : 1,
              keyboardType: takesList ? TextInputType.multiline : TextInputType.text,
              style: const TextStyle(fontSize: 12),
              // 边框、底色沿用主题，只压低高度和弹出按钮对齐
              decoration: InputDecoration(
                // 紧凑输入框的高度是 10 + 上下内边距，6 正好 22px，和弹出按钮一样高
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                hintText: takesList ? '一行一个值' : null,
                helperText: switch (draft.op) {
                  FilterOp.in_ => '列表里不能写 NULL，要找 NULL 另加「为 NULL」',
                  FilterOp.notIn => '列表里不能写 NULL；该列为 NULL 的行不会命中',
                  _ => null,
                },
                helperStyle: const TextStyle(fontSize: 11),
              ),
              onSubmitted: takesList ? null : (_) => _apply(),
            ),
          ),
          const SizedBox(width: 2),
          _removeButton(ValueKey('filter-remove-$key'), '删掉这条', () => _remove(path, index)),
        ],
      ),
    );
  }
}
