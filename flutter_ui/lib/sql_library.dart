import 'package:flutter/material.dart';

import 'src/rust/api/editor.dart';
import 'src/rust/api/editor.dart'
    as editor
    show listHistory, addHistory, listFavorites, saveFavorite, deleteFavorite;

/// 执行历史和收藏。生产环境存在 Rust 侧的 JSON 文件里，测试换成内存实现
abstract class SqlLibrary {
  /// 最新的在前
  Future<List<HistoryEntry>> history();
  Future<void> addHistory(String sql);
  Future<List<Favorite>> favorites();

  /// 同名覆盖，返回 id
  Future<String> saveFavorite(String name, String sql);
  Future<void> deleteFavorite(String id);
}

class RustSqlLibrary implements SqlLibrary {
  const RustSqlLibrary();

  @override
  Future<List<HistoryEntry>> history() => editor.listHistory();

  @override
  Future<void> addHistory(String sql) => editor.addHistory(sql: sql);

  @override
  Future<List<Favorite>> favorites() => editor.listFavorites();

  @override
  Future<String> saveFavorite(String name, String sql) => editor.saveFavorite(name: name, sql: sql);

  @override
  Future<void> deleteFavorite(String id) => editor.deleteFavorite(id: id);
}

/// 历史 / 收藏对话框。点一条返回它的 SQL，交给调用方放进编辑器；关掉返回 null
Future<String?> showSqlLibrary(
  BuildContext context, {
  required SqlLibrary library,
  required String currentSql,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _LibraryDialog(library: library, currentSql: currentSql),
  );
}

class _LibraryDialog extends StatefulWidget {
  final SqlLibrary library;
  final String currentSql;

  const _LibraryDialog({required this.library, required this.currentSql});

  @override
  State<_LibraryDialog> createState() => _LibraryDialogState();
}

class _LibraryDialogState extends State<_LibraryDialog> {
  List<HistoryEntry>? _history;
  List<Favorite>? _favorites;
  String? _error;
  final _search = TextEditingController();
  final _favoriteName = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _favoriteName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final history = await widget.library.history();
      final favorites = await widget.library.favorites();
      if (!mounted) return;
      setState(() {
        _history = history;
        _favorites = favorites;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _saveCurrent() async {
    final name = _favoriteName.text.trim();
    if (name.isEmpty || widget.currentSql.trim().isEmpty) return;
    try {
      await widget.library.saveFavorite(name, widget.currentSql);
      _favoriteName.clear();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _delete(String id) async {
    try {
      await widget.library.deleteFavorite(id);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 520,
        child: DefaultTabController(
          length: 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: TabBar(
                        labelStyle: TextStyle(fontSize: 13),
                        tabs: [
                          Tab(text: '历史'),
                          Tab(text: '收藏'),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      iconSize: 18,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                Expanded(child: TabBarView(children: [_historyTab(), _favoritesTab()])),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _historyTab() {
    final history = _history;
    if (history == null) return const Center(child: Text('加载中…'));

    final keyword = _search.text.trim().toLowerCase();
    final matched = <HistoryEntry>[];
    for (final entry in history) {
      if (keyword.isEmpty || entry.sql.toLowerCase().contains(keyword)) matched.add(entry);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: TextField(
            key: const ValueKey('history-search'),
            controller: _search,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 16),
              hintText: '搜索历史',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: matched.isEmpty
              ? const Center(child: Text('没有记录'))
              : ListView.builder(
                  itemCount: matched.length,
                  itemBuilder: (context, index) {
                    final entry = matched[index];
                    return _SqlTile(
                      title: _formatTime(entry.executedAt),
                      sql: entry.sql,
                      onTap: () => Navigator.of(context).pop(entry.sql),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _favoritesTab() {
    final favorites = _favorites;
    if (favorites == null) return const Center(child: Text('加载中…'));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('favorite-name'),
                  controller: _favoriteName,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '给编辑器里当前的 SQL 起个名字',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _saveCurrent(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _saveCurrent, child: const Text('收藏当前 SQL')),
            ],
          ),
        ),
        Expanded(
          child: favorites.isEmpty
              ? const Center(child: Text('还没有收藏'))
              : ListView.builder(
                  itemCount: favorites.length,
                  itemBuilder: (context, index) {
                    final favorite = favorites[index];
                    return _SqlTile(
                      title: favorite.name,
                      sql: favorite.sql,
                      onTap: () => Navigator.of(context).pop(favorite.sql),
                      trailing: IconButton(
                        key: ValueKey('favorite-delete-${favorite.id}'),
                        tooltip: '删除收藏',
                        iconSize: 16,
                        onPressed: () => _delete(favorite.id),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 本地时区的「年-月-日 时:分」
  String _formatTime(int millis) {
    final time = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}

class _SqlTile extends StatelessWidget {
  final String title;
  final String sql;
  final VoidCallback onTap;
  final Widget? trailing;

  const _SqlTile({required this.title, required this.sql, required this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      onTap: onTap,
      title: Text(title, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      subtitle: Text(
        sql,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, fontFamily: 'Menlo', color: scheme.onSurface),
      ),
      trailing: trailing,
    );
  }
}
