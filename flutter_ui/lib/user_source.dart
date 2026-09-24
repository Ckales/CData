import 'src/rust/api/users.dart';

/// 用户管理取数据的来源。语句生成、转义、拦截当前账号都在 Rust 侧，界面只传选项、显示结果。
/// 生产环境是下面的 Rust 实现，测试里换成内存实现
abstract class UserSource {
  /// 当前账号、账号清单、认证插件、各层可选的权限，一次取齐
  Future<UserAdmin> load();

  /// SHOW GRANTS 分层解析后的项和原文
  Future<AccountGrants> grants(Account account);

  /// 预览变更。password 只有新建和改密码时给，返回的语句里密码是 ***
  Future<ChangePlan> preview(UserChange change, {String? password});

  /// 执行预览过的变更。statement 是预览时拿到的语句，Rust 侧重新生成的不一致就拒绝
  Future<void> apply(UserChange change, String statement, {String? password});
}

class RustUserSource implements UserSource {
  final BigInt sessionId;

  const RustUserSource(this.sessionId);

  @override
  Future<UserAdmin> load() => loadUserAdmin(sessionId: sessionId);

  @override
  Future<AccountGrants> grants(Account account) => accountGrants(sessionId: sessionId, account: account);

  @override
  Future<ChangePlan> preview(UserChange change, {String? password}) {
    return previewUserChange(sessionId: sessionId, change: change, password: password);
  }

  @override
  Future<void> apply(UserChange change, String statement, {String? password}) {
    return applyUserChange(sessionId: sessionId, change: change, password: password, statement: statement);
  }
}
