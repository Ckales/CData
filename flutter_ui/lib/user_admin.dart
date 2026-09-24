import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mac_widgets.dart';
import 'src/rust/api/users.dart';
import 'user_source.dart';

/// 用户与权限对话框：Dialog 里包一个 UserAdminPanel，外加标题和关闭按钮
Future<void> showUserAdmin(BuildContext context, {required UserSource source}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 1100,
        height: 660,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(child: Text('用户与权限', style: Theme.of(context).textTheme.titleMedium)),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(child: UserAdminPanel(source: source)),
          ],
        ),
      ),
    ),
  );
}

const _scopeLabels = {
  GrantScope.global: '全局',
  GrantScope.database: '库',
  GrantScope.table: '表',
  GrantScope.column: '列',
  GrantScope.routine: '存储过程 / 函数',
  GrantScope.role: '角色（角色自带的权限不在这里展开）',
  GrantScope.proxy: '代理',
  GrantScope.unparsed: '未能解析（原文见下方）',
};

const _allPrivileges = 'ALL PRIVILEGES';
const _grantOptionPrivilege = 'GRANT OPTION';

String _label(Account account) => "'${account.user}'@'${account.host}'";

bool _sameAccount(Account a, Account b) => a.user == b.user && a.host == b.host;

/// 表单预览成功后交回的东西：变更、预览、密码（只有新建和改密码有）
class _Prepared {
  final UserChange change;
  final ChangePlan plan;
  final String? password;

  const _Prepared(this.change, this.plan, this.password);
}

/// 表单的标签宽度：标签右对齐，控件左边对齐成一条线
const double _formLabelWidth = 90;

/// 表单里一行输入框：左边标签，右边输入框，note 是输入框下面的一行小字说明
Widget _textField(
  BuildContext context,
  String key,
  TextEditingController controller,
  String label, {
  bool obscure = false,
  String? note,
}) {
  final field = FormRow(
    label: label,
    labelWidth: _formLabelWidth,
    child: TextField(key: ValueKey(key), controller: controller, obscureText: obscure),
  );
  if (note == null) return field;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      field,
      Padding(
        padding: const EdgeInsets.only(left: _formLabelWidth + 8),
        child: Text(note, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
    ],
  );
}

Widget _dropdown<T>(BuildContext context, String key, T value, Map<T, String> items, void Function(T value) onChanged) {
  return Align(
    alignment: Alignment.centerLeft,
    child: MacPopupButton<T>(
      key: ValueKey(key),
      value: value,
      items: items,
      onChanged: onChanged,
    ),
  );
}

/// 紧凑的勾选框：框和文字一起可点，比 CheckboxListTile 矮一半
Widget _check(String key, bool value, Widget label, ValueChanged<bool> onChanged) {
  return InkWell(
    key: ValueKey(key),
    borderRadius: BorderRadius.circular(4),
    onTap: () => onChanged(!value),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(value: value, onChanged: (checked) => onChanged(checked ?? false)),
          ),
          const SizedBox(width: 6),
          Flexible(child: label),
        ],
      ),
    ),
  );
}

Widget _tag(String text, Color background, Color foreground) {
  return Container(
    margin: const EdgeInsets.only(left: 4),
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(3)),
    child: Text(text, style: TextStyle(fontSize: 10, color: foreground)),
  );
}

/// 用户与权限面板：左边账号列表，右边选中账号的操作和权限。没有外框和关闭按钮，可以直接嵌进页面。
///
/// 所有改动先预览 Rust 侧生成的语句，确认后才执行；
/// 当前登录账号的删除、锁定、回收由 Rust 侧在预览时拒绝，这里只显示原因
class UserAdminPanel extends StatefulWidget {
  final UserSource source;

  const UserAdminPanel({super.key, required this.source});

  @override
  State<UserAdminPanel> createState() => _UserAdminPanelState();
}

class _UserAdminPanelState extends State<UserAdminPanel> {
  UserAdmin? _admin;
  String? _loadError;
  Account? _selected;
  AccountGrants? _grants;
  String? _grantsError;
  String? _actionError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final admin = await widget.source.load();
      if (!mounted) return;
      var selected = _selected;
      if (selected == null || !_accounts(admin).any((account) => _sameAccount(account, selected!))) {
        selected = admin.current;
      }
      setState(() {
        _admin = admin;
        _loadError = null;
      });
      await _select(selected);
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  /// 读不了 mysql.user 时只剩当前账号
  List<Account> _accounts(UserAdmin admin) {
    if (admin.usersUnavailable != null) return [admin.current];
    return [for (final row in admin.users) row.account];
  }

  UserRow? _rowOf(Account account) {
    final admin = _admin;
    if (admin == null) return null;
    for (final row in admin.users) {
      if (_sameAccount(row.account, account)) return row;
    }
    return null;
  }

  Future<void> _select(Account account) async {
    setState(() {
      _selected = account;
      _grants = null;
      _grantsError = null;
      _actionError = null;
    });
    try {
      final grants = await widget.source.grants(account);
      if (mounted && _selected == account) setState(() => _grants = grants);
    } catch (e) {
      if (mounted && _selected == account) setState(() => _grantsError = '$e');
    }
  }

  /// 不需要表单的操作（锁定、删除）：直接预览，拒绝的原因显示在右侧
  Future<void> _previewDirect(UserChange change) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final plan = await widget.source.preview(change);
      if (!mounted) return;
      setState(() => _busy = false);
      await _confirm(_Prepared(change, plan, null));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _actionError = '$e';
        });
      }
    }
  }

  Future<void> _openForm(Widget form) async {
    setState(() => _actionError = null);
    final prepared = await showDialog<_Prepared>(context: context, barrierDismissible: false, builder: (_) => form);
    if (prepared != null && mounted) await _confirm(prepared);
  }

  Future<void> _confirm(_Prepared prepared) async {
    final applied = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PreviewDialog(
        plan: prepared.plan,
        apply: () => widget.source.apply(prepared.change, prepared.plan.statement, password: prepared.password),
      ),
    );
    if (applied == true && mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final admin = _admin;
    final loadError = _loadError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MacPanelBar(
          children: [
            if (admin != null)
              Text('当前登录：${_label(admin.current)}', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('刷新'),
            ),
          ],
        ),
        if (loadError != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(loadError, style: TextStyle(color: scheme.error, fontSize: 12)),
          )
        else if (admin == null)
          const Padding(padding: EdgeInsets.all(12), child: Text('加载中…', style: TextStyle(fontSize: 12)))
        else
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 300, child: _userList(admin)),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                Expanded(child: ColoredBox(color: scheme.surface, child: _detail(admin))),
              ],
            ),
          ),
      ],
    );
  }

  /// 账号列表：侧栏灰底，选中行系统蓝；底部一条放「新建用户」，和 macOS 列表下面的 + 一样
  Widget _userList(UserAdmin admin) {
    final scheme = Theme.of(context).colorScheme;
    final unavailable = admin.usersUnavailable;
    final selected = _selected;
    return ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Text(
              unavailable == null ? '账号 ${admin.users.length}' : '账号',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
            ),
          ),
          if (unavailable != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text(unavailable, style: TextStyle(fontSize: 12, color: scheme.error)),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                for (final account in _accounts(admin))
                  _userTile(account, _rowOf(account), selected != null && _sameAccount(account, selected), admin),
              ],
            ),
          ),
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('user-create'),
              onPressed: () => _openForm(_CreateUserDialog(source: widget.source, plugins: admin.plugins)),
              icon: const Icon(Icons.add, size: 14),
              label: const Text('新建用户'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _userTile(Account account, UserRow? row, bool selected, UserAdmin admin) {
    final scheme = Theme.of(context).colorScheme;
    final expired = row?.passwordExpired;
    final isCurrent = row?.isCurrent ?? _sameAccount(account, admin.current);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          key: ValueKey('user-${account.user}@${account.host}'),
          borderRadius: BorderRadius.circular(5),
          onTap: () => _select(account),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.person_outline, size: 14, color: selected ? scheme.onPrimary : scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _label(account),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'Menlo',
                          color: selected ? scheme.onPrimary : scheme.onSurface,
                        ),
                      ),
                    ),
                    if (isCurrent) _tag('当前登录', scheme.primaryContainer, scheme.onPrimaryContainer),
                    if (row != null && row.locked) _tag('已锁定', scheme.errorContainer, scheme.onErrorContainer),
                    if (expired != null)
                      Tooltip(message: expired, child: _tag('密码过期', scheme.errorContainer, scheme.onErrorContainer)),
                  ],
                ),
                if (row != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 20),
                    child: Text(
                      row.plugin,
                      style: TextStyle(fontSize: 11, color: selected ? Colors.white70 : scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detail(UserAdmin admin) {
    final scheme = Theme.of(context).colorScheme;
    final account = _selected;
    if (account == null) return const SizedBox.shrink();
    final row = _rowOf(account);
    final actionError = _actionError;
    final locked = row?.locked ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_label(account), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'Menlo')),
          if (row?.passwordExpired != null)
            Text('密码：${row!.passwordExpired}', style: TextStyle(fontSize: 12, color: scheme.error)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              OutlinedButton(
                key: const ValueKey('user-password'),
                onPressed: _busy ? null : () => _openForm(_PasswordDialog(source: widget.source, account: account)),
                child: const Text('改密码'),
              ),
              OutlinedButton(
                key: const ValueKey('user-lock'),
                onPressed: _busy ? null : () => _previewDirect(UserChange.setLocked(account: account, locked: !locked)),
                child: Text(locked ? '解锁' : '锁定'),
              ),
              OutlinedButton(
                key: const ValueKey('user-grant'),
                onPressed: _busy ? null : () => _openForm(_GrantDialog(source: widget.source, admin: admin, account: account)),
                child: const Text('授予 / 回收权限'),
              ),
              OutlinedButton(
                key: const ValueKey('user-role'),
                onPressed: _busy
                    ? null
                    : () => _openForm(_RoleDialog(
                          source: widget.source,
                          account: account,
                          candidates: [for (final other in _accounts(admin)) if (!_sameAccount(other, account)) other],
                          granted: [
                            for (final entry in _grants?.entries ?? const <GrantEntry>[])
                              if (entry.role != null) entry.role!,
                          ],
                        )),
                child: const Text('角色'),
              ),
              OutlinedButton(
                key: const ValueKey('user-drop'),
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                onPressed: _busy ? null : () => _previewDirect(UserChange.drop(account: account)),
                child: const Text('删除用户'),
              ),
            ],
          ),
          if (actionError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(actionError, style: TextStyle(color: scheme.error, fontSize: 12)),
            ),
          Divider(height: 20, color: scheme.outlineVariant),
          Expanded(child: _grantsView()),
        ],
      ),
    );
  }

  Widget _grantsView() {
    final scheme = Theme.of(context).colorScheme;
    final error = _grantsError;
    if (error != null) return SelectableText(error, style: TextStyle(color: scheme.error, fontSize: 12));
    final grants = _grants;
    if (grants == null) return const Text('加载中…', style: TextStyle(fontSize: 12));

    final raw = grants.statements.join(';\n');
    return ListView(
      children: [
        for (final scope in GrantScope.values)
          if (grants.entries.any((entry) => entry.scope == scope)) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 2),
              child: Text(
                _scopeLabels[scope]!,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
              ),
            ),
            for (final entry in grants.entries)
              if (entry.scope == scope) _grantRow(entry),
          ],
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('SHOW GRANTS 原文', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton(
              key: const ValueKey('grants-copy'),
              onPressed: () => Clipboard.setData(ClipboardData(text: '$raw;')),
              child: const Text('复制'),
            ),
          ],
        ),
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(5),
          ),
          child: SelectableText(raw, style: const TextStyle(fontSize: 12, fontFamily: 'Menlo', height: 1.5)),
        ),
      ],
    );
  }

  Widget _grantRow(GrantEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    if (entry.scope == GrantScope.unparsed) {
      return Text(entry.statement, style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            child: SelectableText(entry.target, style: const TextStyle(fontSize: 12, fontFamily: 'Menlo')),
          ),
          Expanded(child: Text(entry.privileges.join(', '), style: const TextStyle(fontSize: 12))),
          if (entry.grantOption)
            _tag(entry.scope == GrantScope.role ? 'WITH ADMIN OPTION' : 'WITH GRANT OPTION', scheme.tertiaryContainer,
                scheme.onTertiaryContainer),
          if (entry.partialRevoke) _tag('部分回收（从上层权限里扣除）', scheme.errorContainer, scheme.onErrorContainer),
        ],
      ),
    );
  }
}

/// 表单弹窗的外壳：内容、报错、取消 / 预览
class _FormShell extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final String? error;
  final bool previewing;
  final VoidCallback onPreview;

  const _FormShell({
    required this.title,
    required this.children,
    required this.error,
    required this.previewing,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = this.error;
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...children,
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(error, style: TextStyle(color: scheme.error, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: previewing ? null : onPreview, child: Text(previewing ? '生成中…' : '预览')),
      ],
    );
  }
}

/// 表单的预览流程：拿到预览就带着它关掉表单，出错留在表单里
mixin _PreviewForm<T extends StatefulWidget> on State<T> {
  String? error;
  bool previewing = false;

  UserSource get source;

  Future<void> previewAndClose(UserChange change, {String? password}) async {
    setState(() {
      previewing = true;
      error = null;
    });
    try {
      final plan = await source.preview(change, password: password);
      if (mounted) Navigator.of(context).pop(_Prepared(change, plan, password));
    } catch (e) {
      if (mounted) {
        setState(() {
          previewing = false;
          error = '$e';
        });
      }
    }
  }
}

class _CreateUserDialog extends StatefulWidget {
  final UserSource source;
  final List<String> plugins;

  const _CreateUserDialog({required this.source, required this.plugins});

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> with _PreviewForm {
  final _user = TextEditingController();
  final _host = TextEditingController(text: 'localhost');
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _plugin;

  @override
  UserSource get source => widget.source;

  @override
  void dispose() {
    for (final controller in [_user, _host, _password, _confirm]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _preview() {
    if (_password.text != _confirm.text) {
      setState(() => error = '两次输入的密码不一致');
      return;
    }
    final account = Account(user: _user.text, host: _host.text);
    previewAndClose(UserChange.create(account: account, plugin: _plugin), password: _password.text);
  }

  @override
  Widget build(BuildContext context) {
    return _FormShell(
      title: '新建用户',
      error: error,
      previewing: previewing,
      onPreview: _preview,
      children: [
        _textField(context, 'create-user', _user, '用户名'),
        _textField(context, 'create-host', _host, '主机', note: '% 表示任意主机'),
        _textField(context, 'create-password', _password, '密码', obscure: true),
        _textField(context, 'create-confirm', _confirm, '确认密码', obscure: true),
        FormRow(
          label: '认证插件',
          labelWidth: _formLabelWidth,
          child: _dropdown<String?>(
            context,
            'create-plugin',
            _plugin,
            {null: '服务器默认', for (final plugin in widget.plugins) plugin: plugin},
            (plugin) => setState(() => _plugin = plugin),
          ),
        ),
      ],
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  final UserSource source;
  final Account account;

  const _PasswordDialog({required this.source, required this.account});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> with _PreviewForm {
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  UserSource get source => widget.source;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _preview() {
    if (_password.text != _confirm.text) {
      setState(() => error = '两次输入的密码不一致');
      return;
    }
    previewAndClose(UserChange.setPassword(account: widget.account), password: _password.text);
  }

  @override
  Widget build(BuildContext context) {
    return _FormShell(
      title: '改密码：${_label(widget.account)}',
      error: error,
      previewing: previewing,
      onPreview: _preview,
      children: [
        _textField(context, 'password-new', _password, '新密码', obscure: true),
        _textField(context, 'password-confirm', _confirm, '确认新密码', obscure: true),
      ],
    );
  }
}

enum _Level { global, database, table }

class _GrantDialog extends StatefulWidget {
  final UserSource source;
  final UserAdmin admin;
  final Account account;

  const _GrantDialog({required this.source, required this.admin, required this.account});

  @override
  State<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends State<_GrantDialog> with _PreviewForm {
  final _database = TextEditingController();
  final _table = TextEditingController();
  bool _revoke = false;
  _Level _level = _Level.database;
  final Set<String> _checked = {};
  bool _all = false;
  bool _withGrantOption = false;

  @override
  UserSource get source => widget.source;

  @override
  void dispose() {
    _database.dispose();
    _table.dispose();
    super.dispose();
  }

  List<String> get _choices => switch (_level) {
        _Level.global => widget.admin.globalPrivileges,
        _Level.database => widget.admin.databasePrivileges,
        _Level.table => widget.admin.tablePrivileges,
      };

  void _preview() {
    final level = switch (_level) {
      _Level.global => const GrantLevel.global(),
      _Level.database => GrantLevel.database(database: _database.text),
      _Level.table => GrantLevel.table(database: _database.text, table: _table.text),
    };
    final privileges = <String>[
      if (_all) _allPrivileges,
      for (final privilege in _choices)
        if (_checked.contains(privilege)) privilege,
      if (_revoke && _withGrantOption) _grantOptionPrivilege,
    ];
    final change = _revoke
        ? UserChange.revoke(account: widget.account, level: level, privileges: privileges)
        : UserChange.grant(account: widget.account, level: level, privileges: privileges, withGrantOption: _withGrantOption);
    previewAndClose(change);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _FormShell(
      title: '${_revoke ? '回收' : '授予'}权限：${_label(widget.account)}',
      error: error,
      previewing: previewing,
      onPreview: _preview,
      children: [
        FormRow(
          label: '操作',
          labelWidth: _formLabelWidth,
          child: _dropdown<bool>(context, 'grant-mode', _revoke, {false: '授予 GRANT', true: '回收 REVOKE'},
              (revoke) => setState(() => _revoke = revoke)),
        ),
        FormRow(
          label: '范围',
          labelWidth: _formLabelWidth,
          child: _dropdown<_Level>(
            context,
            'grant-level',
            _level,
            {_Level.global: '全局 *.*', _Level.database: '库 db.*', _Level.table: '表 db.tbl'},
            (level) => setState(() {
              _level = level;
              // 换了层级，不在新层级里的勾选作废
              _checked.retainAll(_choices);
            }),
          ),
        ),
        if (_level != _Level.global) _textField(context, 'grant-database', _database, '库名'),
        if (_level == _Level.table) _textField(context, 'grant-table', _table, '表名'),
        Padding(
          padding: const EdgeInsets.only(left: _formLabelWidth + 8, top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _check(
                'grant-all',
                _all,
                Text(_allPrivileges, style: TextStyle(fontSize: 12, color: _revoke ? scheme.error : null)),
                (checked) => setState(() => _all = checked),
              ),
              _check(
                'grant-option',
                _withGrantOption,
                Text(
                  _revoke ? _grantOptionPrivilege : 'WITH GRANT OPTION（可以把权限再授予别人）',
                  style: TextStyle(fontSize: 12, color: _revoke ? scheme.error : null),
                ),
                (checked) => setState(() => _withGrantOption = checked),
              ),
            ],
          ),
        ),
        Divider(height: 16, color: scheme.outlineVariant),
        Padding(
          padding: const EdgeInsets.only(left: _formLabelWidth + 8),
          child: Wrap(
            runSpacing: 2,
            children: [
              for (final privilege in _choices)
                SizedBox(
                  width: 170,
                  child: _check(
                    'grant-privilege-$privilege',
                    _checked.contains(privilege),
                    Text(privilege, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    (checked) => setState(() {
                      if (checked) {
                        _checked.add(privilege);
                      } else {
                        _checked.remove(privilege);
                      }
                    }),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoleDialog extends StatefulWidget {
  final UserSource source;
  final Account account;

  /// 授予时可选的账号（MySQL 8 里任何账号都能当角色用）
  final List<Account> candidates;

  /// 已经授予的角色，回收时从这里选
  final List<Account> granted;

  const _RoleDialog({required this.source, required this.account, required this.candidates, required this.granted});

  @override
  State<_RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<_RoleDialog> with _PreviewForm {
  bool _revoke = false;
  int? _choice;

  @override
  UserSource get source => widget.source;

  List<Account> get _options => _revoke ? widget.granted : widget.candidates;

  void _preview() {
    final choice = _choice;
    if (choice == null) {
      setState(() => error = '没有选角色');
      return;
    }
    final role = _options[choice];
    previewAndClose(_revoke
        ? UserChange.revokeRole(account: widget.account, role: role)
        : UserChange.grantRole(account: widget.account, role: role));
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    return _FormShell(
      title: '角色：${_label(widget.account)}',
      error: error,
      previewing: previewing,
      onPreview: _preview,
      children: [
        FormRow(
          label: '操作',
          labelWidth: _formLabelWidth,
          child: _dropdown<bool>(context, 'role-mode', _revoke, {false: '授予角色', true: '回收角色'},
              (revoke) => setState(() {
                    _revoke = revoke;
                    _choice = null;
                  })),
        ),
        FormRow(
          label: '角色',
          labelWidth: _formLabelWidth,
          child: options.isEmpty
              ? Text(_revoke ? '这个账号没有被授予角色' : '列不出别的账号，没有可选的角色', style: const TextStyle(fontSize: 12))
              : _dropdown<int?>(
                  context,
                  'role-choice',
                  _choice,
                  {null: '选择角色…', for (var i = 0; i < options.length; i++) i: _label(options[i])},
                  (choice) => setState(() => _choice = choice),
                ),
        ),
      ],
    );
  }
}

/// 预览：危险操作醒目标出，执行须知写清楚，确认后才执行
class _PreviewDialog extends StatefulWidget {
  final ChangePlan plan;
  final Future<void> Function() apply;

  const _PreviewDialog({required this.plan, required this.apply});

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  bool _running = false;
  String? _error;

  Future<void> _apply() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await widget.apply();
    } catch (e) {
      if (mounted) {
        setState(() {
          _running = false;
          _error = '$e';
        });
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = widget.plan;
    final error = _error;
    final dangerous = plan.dangers.isNotEmpty;
    return AlertDialog(
      title: const Text('确认要执行的语句'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (dangerous)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(5)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final danger in plan.dangers)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.warning_amber, size: 16, color: scheme.onErrorContainer),
                              const SizedBox(width: 6),
                              Expanded(child: Text(danger, style: TextStyle(fontSize: 12, color: scheme.onErrorContainer))),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              for (final note in plan.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('· $note', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: SelectableText(plan.statement, style: const TextStyle(fontSize: 12, fontFamily: 'Menlo', height: 1.5)),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText('执行失败：$error', style: TextStyle(color: scheme.error, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(onPressed: _running ? null : () => Navigator.of(context).pop(false), child: const Text('返回')),
        FilledButton(
          style: dangerous ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError) : null,
          onPressed: _running ? null : _apply,
          child: Text(_running ? '执行中…' : (dangerous ? '我已了解风险，执行' : '执行')),
        ),
      ],
    );
  }
}
