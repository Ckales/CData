// 高级连接选项对话框的 widget 测试。选项合不合理、SSH 怎么连由 cdata-core 保证，
// 这里管界面：初始值读得对不对、交出去的选项和密码对不对、写错的输入有没有拦下来。

import 'package:cdata_flutter/connection_options.dart';
import 'package:cdata_flutter/src/rust/api/options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaults = ConnectionOptions(
  ssl: SslOptions(mode: SslMode.disabled),
  timeouts: TimeoutOptions(connectSecs: 10),
  ssh: SshOptions(hops: []),
);

/// 编辑态下光标一直闪，pumpAndSettle 等不到稳定，用有限次数的 pump
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

class OpenedDialog {
  ConnectionOptionsResult? result;
  bool closed = false;
}

Future<OpenedDialog> openDialog(
  WidgetTester tester,
  ConnectionOptions initial, {
  Future<String?> Function()? pickFile,
  ThemeData? theme,
}) async {
  final opened = OpenedDialog();
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            opened.result = await showConnectionOptionsDialog(context, initial: initial, pickFile: pickFile);
            opened.closed = true;
          },
          child: const Text('打开'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await settle(tester);
  return opened;
}

Future<void> choose(WidgetTester tester, String key, String label) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await settle(tester);
  await tester.tap(find.byKey(ValueKey(key)));
  await settle(tester);
  await tester.tap(find.text(label).last);
  await settle(tester);
}

Future<void> type(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await settle(tester);
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await settle(tester);
}

Future<void> submit(WidgetTester tester) async {
  await tester.tap(find.text('确定'));
  await settle(tester);
}

void main() {
  testWidgets('不改动直接确定，交回的就是传进来的选项', (tester) async {
    final opened = await openDialog(tester, _defaults);
    expect(find.byKey(const ValueKey('ssl-ca')), findsNothing, reason: '不加密时不显示证书');
    expect(find.byKey(const ValueKey('ssh-host')), findsNothing, reason: '没启用 SSH 时不显示主机');

    await submit(tester);
    expect(opened.closed, isTrue);
    expect(opened.result!.options, _defaults);
    expect(opened.result!.sshSecrets, isEmpty);
  });

  testWidgets('取消返回 null', (tester) async {
    final opened = await openDialog(tester, _defaults);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(opened.closed, isTrue);
    expect(opened.result, isNull);
  });

  testWidgets('SSL：CA 只在校验证书时出现，隐藏的框里残留的内容不带出去', (tester) async {
    final opened = await openDialog(tester, _defaults, pickFile: () async => '/certs/ca.pem');

    await choose(tester, 'ssl-mode', '加密，校验证书和主机名');
    await tapKey(tester, 'ssl-ca-pick');
    expect(find.text('/certs/ca.pem'), findsOneWidget, reason: '选文件的结果要填进框里');

    // 切到不校验证书：CA 框收起来，交出去的 caPath 是 null，不能被 core 当成「填了 CA」
    await choose(tester, 'ssl-mode', '加密，不校验证书');
    expect(find.byKey(const ValueKey('ssl-ca')), findsNothing);
    await type(tester, 'ssl-cert', '/certs/client.pem');
    await type(tester, 'ssl-key', '/certs/client-key.pem');
    await submit(tester);

    final ssl = opened.result!.options.ssl;
    expect(ssl.mode, SslMode.required_);
    expect(ssl.caPath, isNull);
    expect(ssl.certPath, '/certs/client.pem');
    expect(ssl.keyPath, '/certs/client-key.pem');
  });

  testWidgets('超时：写错的值拦下来并说明，留空是不限时', (tester) async {
    final opened = await openDialog(tester, _defaults);

    await type(tester, 'query-timeout', 'abc');
    await submit(tester);
    expect(opened.closed, isFalse, reason: '写错了不能关对话框');
    expect(find.text('查询超时要填正整数秒数，不限时请留空'), findsOneWidget);

    await type(tester, 'query-timeout', '0');
    await submit(tester);
    expect(opened.closed, isFalse, reason: '0 秒说不清是立即超时还是不限，拒绝');

    await type(tester, 'query-timeout', '30');
    await type(tester, 'connect-timeout', '');
    await submit(tester);
    expect(opened.result!.options.timeouts, const TimeoutOptions(connectSecs: null, querySecs: 30));
  });

  testWidgets('SSH：跳板机排在前面，密码和口令按跳对齐，不进 options', (tester) async {
    final opened = await openDialog(tester, _defaults, pickFile: () async => '/home/me/.ssh/id_ed25519');

    await tapKey(tester, 'ssh-enabled');
    await type(tester, 'ssh-host', 'db-gateway.internal');
    await type(tester, 'ssh-user', 'deploy');
    await choose(tester, 'ssh-auth', '私钥');
    await tapKey(tester, 'ssh-key-path-pick');
    await type(tester, 'ssh-secret', 'key passphrase');

    await tapKey(tester, 'jump-enabled');
    await type(tester, 'jump-host', 'bastion.example.com');
    await type(tester, 'jump-port', '2222');
    await type(tester, 'jump-user', 'ops');
    await choose(tester, 'jump-auth', 'ssh-agent');
    expect(find.byKey(const ValueKey('jump-secret')), findsNothing, reason: 'agent 不需要密码');
    await submit(tester);

    final result = opened.result!;
    expect(result.options.ssh.hops, const [
      SshHop(host: 'bastion.example.com', port: 2222, user: 'ops', auth: SshAuth.agent()),
      SshHop(
        host: 'db-gateway.internal',
        port: 22,
        user: 'deploy',
        auth: SshAuth.privateKey(path: '/home/me/.ssh/id_ed25519'),
      ),
    ]);
    expect(result.sshSecrets, [null, 'key passphrase']);
  });

  testWidgets('SSH：必填项没填不关对话框', (tester) async {
    final opened = await openDialog(tester, _defaults);
    await tapKey(tester, 'ssh-enabled');
    await type(tester, 'ssh-host', 'db-gateway.internal');
    await submit(tester);
    expect(opened.closed, isFalse);
    expect(find.text('SSH 主机没有填用户名'), findsOneWidget);
  });

  testWidgets('已保存的两跳配置读进对应的框，不输密码时 sshSecrets 是 null', (tester) async {
    const saved = ConnectionOptions(
      ssl: SslOptions(mode: SslMode.verifyIdentity, caPath: '/certs/ca.pem'),
      timeouts: TimeoutOptions(connectSecs: 5, querySecs: 60),
      ssh: SshOptions(hops: [
        SshHop(host: 'bastion', port: 22, user: 'ops', auth: SshAuth.password()),
        SshHop(host: 'gateway', port: 2200, user: 'deploy', auth: SshAuth.agent()),
      ]),
    );
    final opened = await openDialog(tester, saved);
    expect(find.text('bastion'), findsOneWidget);
    expect(find.text('2200'), findsOneWidget);
    expect(find.text('/certs/ca.pem'), findsOneWidget);

    await submit(tester);
    // 生成的类比较 List 字段用的是引用相等，hops 要单独按元素比
    final options = opened.result!.options;
    expect(options.ssl, saved.ssl);
    expect(options.timeouts, saved.timeouts);
    expect(options.ssh.hops, saved.ssh.hops);
    expect(opened.result!.sshSecrets, [null, null], reason: '没输入的密码交给钥匙串，不能变成空字符串');
  });

  testWidgets('超过两跳的配置原样保留，不让在这里改', (tester) async {
    const hop = SshHop(host: 'h', port: 22, user: 'u', auth: SshAuth.agent());
    const saved = ConnectionOptions(
      ssl: SslOptions(mode: SslMode.disabled),
      timeouts: TimeoutOptions(),
      ssh: SshOptions(hops: [hop, hop, hop]),
    );
    final opened = await openDialog(tester, saved);
    expect(find.textContaining('配置了 3 跳 SSH'), findsOneWidget);
    expect(find.byKey(const ValueKey('ssh-enabled')), findsNothing);

    await submit(tester);
    expect(opened.result!.options.ssh, saved.ssh);
    expect(opened.result!.sshSecrets, [null, null, null]);
  });

  testWidgets('深色主题下错误提示用主题的 error 色，不写死颜色', (tester) async {
    final dark = ThemeData(brightness: Brightness.dark, colorSchemeSeed: Colors.indigo);
    await openDialog(tester, _defaults, theme: dark);
    await type(tester, 'connect-timeout', '-1');
    await submit(tester);

    final error = tester.widget<Text>(find.text('连接超时要填正整数秒数，不限时请留空'));
    expect(error.style?.color, dark.colorScheme.error);
  });
}
