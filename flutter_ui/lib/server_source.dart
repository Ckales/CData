import 'src/rust/api/server.dart';
// 顶层函数和下面 ServerSource 的同名方法重名，方法体里直接调会解析成方法自己
import 'src/rust/api/server.dart' as server
    show slowLogConfig, slowLogEntries, previewSetGlobal, applySetGlobal;
import 'src/rust/api/value.dart' show DisplayCell;

/// 服务器状态页的数据源。生产环境走 Rust，测试换成内存实现。
///
/// KILL 和 SET GLOBAL 的拦截（自己的连接、目标变了、语句和预览不一致）都在 core 里，
/// 界面只负责让用户看清楚、确认两次。
abstract class ServerSource {
  Future<ProcessList> processes();

  /// target 是用户确认时看到的那一行
  Future<void> kill(ProcessInfo target, KillMode mode);

  Future<VariableList> variables(VariableScope scope);

  /// previous 是上一次拿到的快照，差值和每秒增量由 core 按它算
  Future<StatusSnapshot> status(StatusSnapshot? previous);

  Future<SlowLogConfig> slowLogConfig();

  /// mysql.slow_log 最近 limit 条。log_output 不含 TABLE 时抛错并说明日志在哪
  Future<List<SlowLogEntry>> slowLogEntries(int limit);

  Future<SetVariablePlan> previewSetGlobal(String name, String value);

  /// 执行预览过的 SET GLOBAL，返回服务器存下的新值
  Future<DisplayCell> applySetGlobal(String name, String value, String statement);
}

class RustServerSource implements ServerSource {
  final BigInt sessionId;

  const RustServerSource(this.sessionId);

  @override
  Future<ProcessList> processes() => serverProcesses(sessionId: sessionId);

  @override
  Future<void> kill(ProcessInfo target, KillMode mode) {
    return killProcess(sessionId: sessionId, target: target, mode: mode);
  }

  @override
  Future<VariableList> variables(VariableScope scope) => serverVariables(sessionId: sessionId, scope: scope);

  @override
  Future<StatusSnapshot> status(StatusSnapshot? previous) {
    return serverStatus(sessionId: sessionId, previous: previous);
  }

  @override
  Future<SlowLogConfig> slowLogConfig() => server.slowLogConfig(sessionId: sessionId);

  @override
  Future<List<SlowLogEntry>> slowLogEntries(int limit) {
    return server.slowLogEntries(sessionId: sessionId, limit: limit);
  }

  @override
  Future<SetVariablePlan> previewSetGlobal(String name, String value) {
    return server.previewSetGlobal(sessionId: sessionId, name: name, value: value);
  }

  @override
  Future<DisplayCell> applySetGlobal(String name, String value, String statement) {
    return server.applySetGlobal(sessionId: sessionId, name: name, value: value, statement: statement);
  }
}
