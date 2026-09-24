import 'package:flutter/material.dart';

import 'mac_widgets.dart';
import 'src/rust/api/options.dart';

/// 高级连接选项对话框的结果。
///
/// sshSecrets 和 options.ssh.hops 一一对应：这次输入的 SSH 密码或私钥口令，没输入是 null
/// （连接时 core 会去钥匙串里找这条保存的连接存过的那份）。密码不在 options 里，options 会存进配置文件
typedef ConnectionOptionsResult = ({ConnectionOptions options, List<String?> sshSecrets});

/// SSL / 超时 / SSH 隧道。取消返回 null。
///
/// 不调用 FFI，方便 widget 测试；选文件的对话框由调用方通过 pickFile 注入，不给就只能手输路径
Future<ConnectionOptionsResult?> showConnectionOptionsDialog(
  BuildContext context, {
  required ConnectionOptions initial,
  Future<String?> Function()? pickFile,
}) {
  return showDialog(
    context: context,
    builder: (context) => _ConnectionOptionsDialog(initial: initial, pickFile: pickFile),
  );
}

class _ConnectionOptionsDialog extends StatefulWidget {
  final ConnectionOptions initial;
  final Future<String?> Function()? pickFile;

  const _ConnectionOptionsDialog({required this.initial, required this.pickFile});

  @override
  State<_ConnectionOptionsDialog> createState() => _ConnectionOptionsDialogState();
}

/// 一跳 SSH 的输入框。SSH 主机一份，每台跳板机各一份
class _HopInput {
  final host = TextEditingController();
  final port = TextEditingController(text: '22');
  final user = TextEditingController();
  final keyPath = TextEditingController();
  final secret = TextEditingController();
  _AuthKind auth = _AuthKind.password;

  _HopInput();

  _HopInput.from(SshHop hop) {
    host.text = hop.host;
    port.text = hop.port.toString();
    user.text = hop.user;
    switch (hop.auth) {
      case SshAuth_Password():
        auth = _AuthKind.password;
      case SshAuth_PrivateKey(:final path):
        auth = _AuthKind.privateKey;
        keyPath.text = path;
      case SshAuth_Agent():
        auth = _AuthKind.agent;
    }
  }

  void dispose() {
    host.dispose();
    port.dispose();
    user.dispose();
    keyPath.dispose();
    secret.dispose();
  }
}

enum _AuthKind { password, privateKey, agent }

class _ConnectionOptionsDialogState extends State<_ConnectionOptionsDialog> {
  late SslMode _sslMode = widget.initial.ssl.mode;
  late final _caPath = TextEditingController(text: widget.initial.ssl.caPath ?? '');
  late final _certPath = TextEditingController(text: widget.initial.ssl.certPath ?? '');
  late final _keyPath = TextEditingController(text: widget.initial.ssl.keyPath ?? '');
  late final _connectSecs = TextEditingController(text: widget.initial.timeouts.connectSecs?.toString() ?? '');
  late final _querySecs = TextEditingController(text: widget.initial.timeouts.querySecs?.toString() ?? '');

  late final List<SshHop> _initialHops = widget.initial.ssh.hops;
  late bool _useSsh = _initialHops.isNotEmpty;

  /// 最后一跳：MySQL 的连接从这台机器发出
  late final _target = _initialHops.isEmpty ? _HopInput() : _HopInput.from(_initialHops.last);

  /// 跳板机，按连接顺序：第一个是本机最先连上的那台
  late final List<_HopInput> _jumps = [
    for (var i = 0; i < _initialHops.length - 1; i++) _HopInput.from(_initialHops[i]),
  ];

  String? _error;

  @override
  void dispose() {
    for (final controller in [_caPath, _certPath, _keyPath, _connectSecs, _querySecs]) {
      controller.dispose();
    }
    _target.dispose();
    for (final jump in _jumps) {
      jump.dispose();
    }
    super.dispose();
  }

  String? _optionalText(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : text;
  }

  /// 空表示不限时。填了就必须是正整数，不把写错的值当成「不限」
  int? _parseSeconds(String label, TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final seconds = int.tryParse(text);
    if (seconds == null || seconds <= 0) throw FormatException('$label要填正整数秒数，不限时请留空');
    return seconds;
  }

  SshHop _readHop(String label, _HopInput input) {
    final host = input.host.text.trim();
    final user = input.user.text.trim();
    final port = int.tryParse(input.port.text.trim());
    if (host.isEmpty) throw FormatException('$label没有填主机');
    if (user.isEmpty) throw FormatException('$label没有填用户名');
    if (port == null || port <= 0 || port > 65535) throw FormatException('$label的端口要在 1 到 65535 之间');

    final SshAuth auth;
    switch (input.auth) {
      case _AuthKind.password:
        auth = const SshAuth.password();
      case _AuthKind.privateKey:
        final path = input.keyPath.text.trim();
        if (path.isEmpty) throw FormatException('$label没有填私钥文件');
        auth = SshAuth.privateKey(path: path);
      case _AuthKind.agent:
        auth = const SshAuth.agent();
    }
    return SshHop(host: host, port: port, user: user, auth: auth);
  }

  String? _readSecret(_HopInput input) {
    // agent 用不上密码；输入框也不显示，不把之前残留的内容带出去
    if (input.auth == _AuthKind.agent) return null;
    return input.secret.text.isEmpty ? null : input.secret.text;
  }

  void _submit() {
    try {
      final ssl = SslOptions(
        mode: _sslMode,
        // 界面上只在对应模式下显示这些框，隐藏着的内容不带出去
        caPath: _sslMode == SslMode.verifyIdentity ? _optionalText(_caPath) : null,
        certPath: _sslMode == SslMode.disabled ? null : _optionalText(_certPath),
        keyPath: _sslMode == SslMode.disabled ? null : _optionalText(_keyPath),
      );
      final timeouts = TimeoutOptions(
        connectSecs: _parseSeconds('连接超时', _connectSecs),
        querySecs: _parseSeconds('查询超时', _querySecs),
      );

      SshOptions ssh;
      List<String?> secrets;
      if (!_useSsh) {
        ssh = const SshOptions(hops: []);
        secrets = const [];
      } else {
        final hops = <SshHop>[];
        secrets = [];
        for (var i = 0; i < _jumps.length; i++) {
          hops.add(_readHop('跳板机 ${i + 1} ', _jumps[i]));
          secrets.add(_readSecret(_jumps[i]));
        }
        hops.add(_readHop('SSH 主机', _target));
        secrets.add(_readSecret(_target));
        ssh = SshOptions(hops: hops);
      }

      final options = ConnectionOptions(ssl: ssl, timeouts: timeouts, ssh: ssh);
      Navigator.of(context).pop((options: options, sshSecrets: secrets));
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('高级连接选项'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _section('SSL'),
              _row(
                '模式',
                _dropdown<SslMode>('ssl-mode', _sslMode, const {
                  SslMode.disabled: '不加密',
                  SslMode.required_: '加密，不校验证书',
                  SslMode.verifyIdentity: '加密，校验证书和主机名',
                }, (value) => _sslMode = value),
              ),
              if (_sslMode == SslMode.verifyIdentity)
                _row('CA 证书', _pathField('ssl-ca', _caPath, '留空用内置的公共 CA')),
              if (_sslMode != SslMode.disabled) ...[
                _row('客户端证书', _pathField('ssl-cert', _certPath, '可选，和私钥一起填')),
                _row('客户端私钥', _pathField('ssl-key', _keyPath, '可选，和证书一起填')),
              ],
              _section('超时'),
              _row('连接（秒）', _textField('connect-timeout', _connectSecs, '留空不限')),
              _row('查询（秒）', _textField('query-timeout', _querySecs, '留空不限；超时后让服务器停止这条语句')),
              _section('SSH 隧道'),
              _row('启用', _checkbox('ssh-enabled', _useSsh, '经 SSH 隧道连接', (value) => _useSsh = value)),
              if (_useSsh) ...[
                // 跳板机按连接顺序排在前面，SSH 主机是最后一跳
                for (var i = 0; i < _jumps.length; i++) ...[
                  _jumpHeader(i, colors),
                  ..._hopFields('jump-$i', _jumps[i]),
                ],
                if (_jumps.isNotEmpty) _subheader(Text('SSH 主机（最后一跳）', style: _subheaderStyle(colors))),
                ..._hopFields('ssh', _target),
                Padding(
                  padding: const EdgeInsets.only(left: _labelWidth + 4),
                  child: TextButton.icon(
                    key: const ValueKey('jump-add'),
                    onPressed: () => setState(() => _jumps.add(_HopInput())),
                    icon: const Icon(Icons.add, size: 14),
                    label: Text(_jumps.isEmpty ? '经跳板机' : '再加一台跳板机', style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(fontSize: 12, color: colors.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }

  static const double _labelWidth = 90;

  TextStyle _subheaderStyle(ColorScheme colors) {
    return TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: colors.onSurfaceVariant);
  }

  /// 每一跳上面一行小标题，和控件左边对齐
  Widget _subheader(Widget child) {
    return Padding(
      padding: const EdgeInsets.only(left: _labelWidth + 8, top: 6),
      child: child,
    );
  }

  Widget _jumpHeader(int index, ColorScheme colors) {
    final order = index == 0 ? '，本机最先连这台' : '';
    return _subheader(Row(
      children: [
        Text('跳板机 ${index + 1}$order', style: _subheaderStyle(colors)),
        const Spacer(),
        IconButton(
          key: ValueKey('jump-$index-remove'),
          tooltip: '去掉这台跳板机',
          iconSize: 16,
          onPressed: () {
            final removed = _jumps[index];
            setState(() => _jumps.removeAt(index));
            // 这一帧里输入框还挂着，等它们卸下来再释放控制器
            WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
          },
          icon: const Icon(Icons.close),
        ),
      ],
    ));
  }

  List<Widget> _hopFields(String prefix, _HopInput input) {
    return [
      _row('主机', _textField('$prefix-host', input.host, null)),
      _row('端口', _textField('$prefix-port', input.port, null)),
      _row('用户', _textField('$prefix-user', input.user, null)),
      _row(
        '认证',
        _dropdown<_AuthKind>('$prefix-auth', input.auth, const {
          _AuthKind.password: '密码',
          _AuthKind.privateKey: '私钥',
          _AuthKind.agent: 'ssh-agent',
        }, (value) => input.auth = value),
      ),
      if (input.auth == _AuthKind.privateKey)
        _row('私钥文件', _pathField('$prefix-key-path', input.keyPath, null)),
      if (input.auth != _AuthKind.agent)
        _row(
          input.auth == _AuthKind.password ? '密码' : '私钥口令',
          _textField('$prefix-secret', input.secret, '留空使用钥匙串里保存的', obscure: true),
        ),
    ];
  }

  /// 分组标题：粗体小字，上面留出和上一组的间距，像 macOS 偏好设置里的分组
  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }

  Widget _row(String label, Widget field) {
    return FormRow(
      label: label,
      labelWidth: _labelWidth,
      child: Align(alignment: Alignment.centerLeft, child: field),
    );
  }

  Widget _textField(String key, TextEditingController controller, String? hint, {bool obscure = false}) {
    return TextField(
      key: ValueKey(key),
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(hintText: hint),
    );
  }

  Widget _pathField(String key, TextEditingController controller, String? hint) {
    final pickFile = widget.pickFile;
    return Row(
      children: [
        Expanded(child: _textField(key, controller, hint)),
        if (pickFile != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: OutlinedButton(
              key: ValueKey('$key-pick'),
              onPressed: () async {
                final path = await pickFile();
                if (path != null && mounted) setState(() => controller.text = path);
              },
              child: const Text('选择…'),
            ),
          ),
      ],
    );
  }

  /// 勾选框和它的说明文字一起可点
  Widget _checkbox(String key, bool value, String label, void Function(bool value) onChanged) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => setState(() => onChanged(!value)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              key: ValueKey(key),
              value: value,
              onChanged: (checked) => setState(() => onChanged(checked ?? false)),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _dropdown<T>(String key, T value, Map<T, String> items, void Function(T value) onChanged) {
    return MacPopupButton<T>(
      key: ValueKey(key),
      value: value,
      items: items,
      onChanged: (selected) => setState(() => onChanged(selected)),
    );
  }
}
