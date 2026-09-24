// 用户管理的 widget 测试。语句怎么生成、密码怎么转义、当前账号怎么拦由 cdata-core 的测试保证，
// 这里只验证界面把表单正确拼成变更、预览和执行的流程、各种提示显示出来。

import 'package:cdata_flutter/src/rust/api/users.dart';
import 'package:cdata_flutter/user_admin.dart';
import 'package:cdata_flutter/user_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const me = Account(user: 'admin', host: '%');
const bob = Account(user: 'bob', host: 'localhost');
const reporter = Account(user: 'reporter', host: '%');

class FakeUserSource implements UserSource {
  UserAdmin admin;
  final Map<String, AccountGrants> grantsByUser = {};
  final List<(UserChange, String?)> previews = [];
  final List<(UserChange, String, String?)> applied = [];
  int loads = 0;

  /// 下一次预览返回的东西；previewError 不为空就抛它
  ChangePlan plan = const ChangePlan(statement: 'SELECT 1', dangers: [], notes: []);
  String? previewError;

  FakeUserSource(this.admin);

  @override
  Future<UserAdmin> load() async {
    loads++;
    return admin;
  }

  @override
  Future<AccountGrants> grants(Account account) async {
    return grantsByUser[account.user] ?? const AccountGrants(entries: [], statements: []);
  }

  @override
  Future<ChangePlan> preview(UserChange change, {String? password}) async {
    previews.add((change, password));
    final error = previewError;
    if (error != null) throw error;
    return plan;
  }

  @override
  Future<void> apply(UserChange change, String statement, {String? password}) async {
    applied.add((change, statement, password));
  }
}

UserRow row(Account account, {bool locked = false, String? expired, bool current = false}) {
  return UserRow(
    account: account,
    plugin: 'caching_sha2_password',
    locked: locked,
    passwordExpired: expired,
    isCurrent: current,
  );
}

UserAdmin sampleAdmin() {
  return UserAdmin(
    current: me,
    users: [
      row(me, current: true),
      row(bob, locked: true),
      row(reporter, expired: '超过了账号设定的 90 天有效期'),
    ],
    usersUnavailable: null,
    plugins: const ['caching_sha2_password', 'sha256_password'],
    globalPrivileges: const ['SELECT', 'RELOAD'],
    databasePrivileges: const ['SELECT', 'INSERT'],
    tablePrivileges: const ['SELECT', 'INSERT'],
  );
}

GrantEntry entry(GrantScope scope, String target, List<String> privileges, String statement,
    {bool grantOption = false, Account? role}) {
  return GrantEntry(
    scope: scope,
    target: target,
    privileges: privileges,
    grantOption: grantOption,
    partialRevoke: false,
    role: role,
    statement: statement,
  );
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<FakeUserSource> openAdmin(WidgetTester tester, {UserAdmin? admin}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final source = FakeUserSource(admin ?? sampleAdmin());
  const bobGrants = [
    'GRANT USAGE ON *.* TO `bob`@`localhost`',
    'GRANT SELECT, INSERT ON `shop`.* TO `bob`@`localhost` WITH GRANT OPTION',
    'GRANT SELECT (`amount`) ON `shop`.`orders` TO `bob`@`localhost`',
    'GRANT `reporter`@`%` TO `bob`@`localhost`',
  ];
  source.grantsByUser['bob'] = AccountGrants(
    entries: [
      entry(GrantScope.global, '*.*', ['USAGE'], bobGrants[0]),
      entry(GrantScope.database, 'shop.*', ['SELECT', 'INSERT'], bobGrants[1], grantOption: true),
      entry(GrantScope.column, 'shop.orders.amount', ['SELECT'], bobGrants[2]),
      entry(GrantScope.role, "'reporter'@'%'", [], bobGrants[3], role: reporter),
    ],
    statements: bobGrants,
  );

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showUserAdmin(context, source: source),
          child: const Text('打开'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await settle(tester);
  return source;
}

Future<void> selectBob(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('user-bob@localhost')));
  await settle(tester);
}

void main() {
  testWidgets('账号清单标出当前登录、锁定、过期；选中后按层显示权限和原文', (tester) async {
    await openAdmin(tester);
    expect(find.text('当前登录'), findsOneWidget);
    expect(find.text('已锁定'), findsOneWidget);
    expect(find.text('密码过期'), findsOneWidget);
    expect(find.text("当前登录：'admin'@'%'"), findsOneWidget);

    await selectBob(tester);
    expect(find.text('解锁'), findsOneWidget, reason: 'bob 已锁定，按钮是解锁');
    for (final header in ['全局', '库', '列']) {
      expect(find.text(header), findsOneWidget);
    }
    expect(find.textContaining('角色（'), findsOneWidget);
    expect(find.text('shop.orders.amount'), findsOneWidget);
    expect(find.text('WITH GRANT OPTION'), findsOneWidget);
    expect(find.text('SHOW GRANTS 原文'), findsOneWidget);
    expect(find.textContaining('GRANT SELECT (`amount`) ON `shop`.`orders`'), findsOneWidget);
    expect(find.byKey(const ValueKey('grants-copy')), findsOneWidget);
  });

  testWidgets('读不了 mysql.user 时显示原因，只列当前账号', (tester) async {
    final admin = sampleAdmin();
    await openAdmin(
      tester,
      admin: UserAdmin(
        current: me,
        users: const [],
        usersUnavailable: '当前账号没有读 mysql.user 的权限',
        plugins: admin.plugins,
        globalPrivileges: admin.globalPrivileges,
        databasePrivileges: admin.databasePrivileges,
        tablePrivileges: admin.tablePrivileges,
      ),
    );
    expect(find.text('当前账号没有读 mysql.user 的权限'), findsOneWidget);
    expect(find.byKey(const ValueKey('user-admin@%')), findsOneWidget);
    expect(find.byKey(const ValueKey('user-bob@localhost')), findsNothing);
  });

  testWidgets('新建用户：两次密码不一致在界面拦下；一致后密码单独传，预览里只有 ***', (tester) async {
    final source = await openAdmin(tester);
    await tester.tap(find.byKey(const ValueKey('user-create')));
    await settle(tester);

    await tester.enterText(find.byKey(const ValueKey('create-user')), 'carol');
    await tester.enterText(find.byKey(const ValueKey('create-host')), '10.0.%');
    await tester.enterText(find.byKey(const ValueKey('create-password')), "p'w\\1");
    await tester.enterText(find.byKey(const ValueKey('create-confirm')), 'other');
    await tester.tap(find.text('预览'));
    await settle(tester);
    expect(find.text('两次输入的密码不一致'), findsOneWidget);
    expect(source.previews, isEmpty);

    await tester.enterText(find.byKey(const ValueKey('create-confirm')), "p'w\\1");
    await tester.tap(find.byKey(const ValueKey('create-plugin')));
    await settle(tester);
    await tester.tap(find.text('sha256_password').last);
    await settle(tester);

    source.plan = const ChangePlan(
      statement: "CREATE USER `carol`@`10.0.%` IDENTIFIED WITH sha256_password BY '***'",
      dangers: [],
      notes: ['密码在预览里显示为 ***，只在执行时发给服务器'],
    );
    await tester.tap(find.text('预览'));
    await settle(tester);

    final (change, password) = source.previews.single;
    expect(change, const UserChange.create(account: Account(user: 'carol', host: '10.0.%'), plugin: 'sha256_password'));
    expect(password, "p'w\\1");
    expect(find.text('确认要执行的语句'), findsOneWidget);
    expect(find.textContaining("BY '***'"), findsOneWidget);

    final loadsBefore = source.loads;
    await tester.tap(find.text('执行'));
    await settle(tester);
    final (appliedChange, statement, appliedPassword) = source.applied.single;
    expect(appliedChange, change);
    expect(statement, source.plan.statement, reason: '执行时带上预览的语句，Rust 侧据此核对');
    expect(appliedPassword, "p'w\\1");
    expect(source.loads, greaterThan(loadsBefore), reason: '执行后重读账号清单');
  });

  testWidgets('删除：预览列出风险，执行按钮换成「我已了解风险」', (tester) async {
    final source = await openAdmin(tester);
    await selectBob(tester);
    source.plan = const ChangePlan(
      statement: 'DROP USER `bob`@`localhost`',
      dangers: ['DROP USER 不会断开这个账号已有的连接'],
      notes: [],
    );
    await tester.tap(find.byKey(const ValueKey('user-drop')));
    await settle(tester);

    expect(source.previews.single.$1, const UserChange.drop(account: bob));
    expect(source.previews.single.$2, isNull);
    expect(find.text('DROP USER 不会断开这个账号已有的连接'), findsOneWidget);
    await tester.tap(find.text('我已了解风险，执行'));
    await settle(tester);
    expect(source.applied.single.$2, 'DROP USER `bob`@`localhost`');
  });

  testWidgets('当前账号：Rust 侧拒绝的原因显示出来，不弹预览、不执行', (tester) async {
    final source = await openAdmin(tester);
    source.previewError = "'admin'@'%' 是当前登录的账号，不能锁定";
    await tester.tap(find.byKey(const ValueKey('user-lock')));
    await settle(tester);

    expect(source.previews.single.$1, const UserChange.setLocked(account: me, locked: true));
    expect(find.text("'admin'@'%' 是当前登录的账号，不能锁定"), findsOneWidget);
    expect(find.text('确认要执行的语句'), findsNothing);
    expect(source.applied, isEmpty);
  });

  testWidgets('授予库级权限带 WITH GRANT OPTION；回收 ALL 和 GRANT OPTION 拼进权限列表', (tester) async {
    final source = await openAdmin(tester);
    await selectBob(tester);

    await tester.tap(find.byKey(const ValueKey('user-grant')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('grant-database')), 'shop');
    await tester.tap(find.byKey(const ValueKey('grant-privilege-INSERT')));
    await tester.tap(find.byKey(const ValueKey('grant-option')));
    await settle(tester);
    await tester.tap(find.text('预览'));
    await settle(tester);
    expect(
      source.previews.last.$1,
      const UserChange.grant(
        account: bob,
        level: GrantLevel.database(database: 'shop'),
        privileges: ['INSERT'],
        withGrantOption: true,
      ),
    );
    await tester.tap(find.text('返回'));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('user-grant')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('grant-mode')));
    await settle(tester);
    await tester.tap(find.text('回收 REVOKE').last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('grant-level')));
    await settle(tester);
    await tester.tap(find.text('全局 *.*').last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('grant-all')));
    await tester.tap(find.byKey(const ValueKey('grant-option')));
    await settle(tester);
    source.plan = const ChangePlan(
      statement: 'REVOKE ALL PRIVILEGES, GRANT OPTION ON *.* FROM `bob`@`localhost`',
      dangers: ['回收 ALL PRIVILEGES', '回收 GRANT OPTION'],
      notes: [],
    );
    await tester.tap(find.text('预览'));
    await settle(tester);
    expect(
      source.previews.last.$1,
      const UserChange.revoke(
        account: bob,
        level: GrantLevel.global(),
        privileges: ['ALL PRIVILEGES', 'GRANT OPTION'],
      ),
    );
    expect(find.text('回收 ALL PRIVILEGES'), findsOneWidget);
    expect(find.text('我已了解风险，执行'), findsOneWidget);
  });

  testWidgets('回收角色只从已授予的角色里选', (tester) async {
    final source = await openAdmin(tester);
    await selectBob(tester);
    await tester.tap(find.byKey(const ValueKey('user-role')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('role-mode')));
    await settle(tester);
    await tester.tap(find.text('回收角色').last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('role-choice')));
    await settle(tester);
    await tester.tap(find.text("'reporter'@'%'").last);
    await settle(tester);
    await tester.tap(find.text('预览'));
    await settle(tester);
    expect(source.previews.single.$1, const UserChange.revokeRole(account: bob, role: reporter));
  });
}
