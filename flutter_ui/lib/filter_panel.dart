import 'package:flutter/material.dart';

import 'src/rust/api/db.dart';

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
  };
}

/// IS NULL 这类运算符不看值
bool filterOpTakesValue(FilterOp op) => op != FilterOp.isNull && op != FilterOp.isNotNull;

/// 一句话描述当前筛选，比如「amount > 10 且 name 包含 张」
String describeFilter(List<FilterCondition> conditions, bool matchAll) {
  final parts = <String>[];
  for (final condition in conditions) {
    final op = filterOpLabel(condition.op);
    parts.add(filterOpTakesValue(condition.op)
        ? '${condition.column} $op ${condition.value}'
        : '${condition.column} $op');
  }
  return parts.join(matchAll ? ' 且 ' : ' 或 ');
}

/// 结果上方的筛选条：当前条件的摘要 + 编辑 / 清除入口
class FilterBar extends StatelessWidget {
  final List<FilterCondition> conditions;
  final bool matchAll;
  final VoidCallback? onEdit;
  final VoidCallback? onClear;

  const FilterBar({
    super.key,
    required this.conditions,
    required this.matchAll,
    required this.onEdit,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.filter_alt_outlined, size: 16),
            label: const Text('筛选', style: TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Text(
              conditions.isEmpty ? '未筛选' : describeFilter(conditions, matchAll),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFamily: conditions.isEmpty ? null : 'Menlo',
                color: conditions.isEmpty ? Colors.black38 : Colors.black87,
              ),
            ),
          ),
          if (conditions.isNotEmpty)
            TextButton(onPressed: onClear, child: const Text('清除', style: TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

/// 编辑筛选条件。返回新的条件和组合方式；取消返回 null，一条都不留就是清除筛选
Future<({List<FilterCondition> conditions, bool matchAll})?> showFilterDialog(
  BuildContext context, {
  required List<String> columns,
  required List<FilterCondition> initial,
  required bool matchAll,
}) {
  return showDialog(
    context: context,
    builder: (context) => _FilterDialog(columns: columns, initial: initial, matchAll: matchAll),
  );
}

/// 编辑中的一条条件
class _Draft {
  String column;
  FilterOp op;
  final TextEditingController value;

  _Draft({required this.column, required this.op, required String value})
      : value = TextEditingController(text: value);
}

class _FilterDialog extends StatefulWidget {
  final List<String> columns;
  final List<FilterCondition> initial;
  final bool matchAll;

  const _FilterDialog({required this.columns, required this.initial, required this.matchAll});

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  final List<_Draft> _drafts = [];
  late bool _matchAll = widget.matchAll;

  @override
  void initState() {
    super.initState();
    for (final condition in widget.initial) {
      _drafts.add(_Draft(column: condition.column, op: condition.op, value: condition.value));
    }
    // 第一次打开给一条空的，省得再点「添加条件」
    if (_drafts.isEmpty) _addDraft();
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.value.dispose();
    }
    super.dispose();
  }

  void _addDraft() {
    _drafts.add(_Draft(column: widget.columns.first, op: FilterOp.eq, value: ''));
  }

  void _removeDraft(int index) {
    setState(() => _drafts.removeAt(index).value.dispose());
  }

  void _apply() {
    final conditions = <FilterCondition>[];
    for (final draft in _drafts) {
      conditions.add(FilterCondition(
        column: draft.column,
        op: draft.op,
        // 不看值的运算符不带值，免得描述里出现残留的旧输入
        value: filterOpTakesValue(draft.op) ? draft.value.text : '',
      ));
    }
    Navigator.of(context).pop((conditions: conditions, matchAll: _matchAll));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Text('筛选', style: TextStyle(fontSize: 16)),
          const Spacer(),
          DropdownButton<bool>(
            key: const ValueKey('filter-match'),
            value: _matchAll,
            isDense: true,
            style: const TextStyle(fontSize: 12, color: Colors.black87),
            items: const [
              DropdownMenuItem(value: true, child: Text('满足全部条件')),
              DropdownMenuItem(value: false, child: Text('满足任一条件')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _matchAll = value);
            },
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < _drafts.length; i++) _draftRow(i),
              TextButton.icon(
                onPressed: () => setState(_addDraft),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加条件', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _apply, child: const Text('应用')),
      ],
    );
  }

  Widget _draftRow(int index) {
    final draft = _drafts[index];
    // 条件里的列不在当前列里时也列出来，让人看得见、能改掉，而不是让下拉框直接崩
    final columns = [...widget.columns];
    if (!columns.contains(draft.column)) columns.add(draft.column);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: DropdownButton<String>(
              key: ValueKey('filter-column-$index'),
              value: draft.column,
              isDense: true,
              isExpanded: true,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
              items: [
                for (final column in columns)
                  DropdownMenuItem(value: column, child: Text(column, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (column) {
                if (column != null) setState(() => draft.column = column);
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: DropdownButton<FilterOp>(
              key: ValueKey('filter-op-$index'),
              value: draft.op,
              isDense: true,
              isExpanded: true,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
              items: [
                for (final op in FilterOp.values)
                  DropdownMenuItem(value: op, child: Text(filterOpLabel(op))),
              ],
              onChanged: (op) {
                if (op != null) setState(() => draft.op = op);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: ValueKey('filter-value-$index'),
              controller: draft.value,
              enabled: filterOpTakesValue(draft.op),
              style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              ),
              onSubmitted: (_) => _apply(),
            ),
          ),
          IconButton(
            key: ValueKey('filter-remove-$index'),
            tooltip: '删掉这条',
            iconSize: 16,
            onPressed: () => _removeDraft(index),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
