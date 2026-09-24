#!/bin/zsh
# 集成测试逐文件独立跑。
#
# 这里只剩两件事：FFI 链路的类型保真，和一条端到端冒烟（顺便出图）。
# 细粒度的 UI 行为都在 test/ 下的 widget 测试里，`flutter test` 秒级跑完。
#
# 逐文件跑而不是合并：所有用例挤在一个 app 进程里，前面遗留的未完成 FFI 调用
# 会把后面的 runAsync 越拖越慢。每个文件独立起一次 app，进程退出就清干净了。
#
# 用法：先导出 CDATA_TEST_* 环境变量（见 README 的「开发」一节），再跑本脚本。

set -e
cd "$(dirname "$0")"

DEFINES=(
  --dart-define=HOST=$CDATA_TEST_HOST
  --dart-define=PORT=$CDATA_TEST_PORT
  --dart-define=USER=$CDATA_TEST_USER
  --dart-define=PASSWORD=$CDATA_TEST_PASSWORD
  --dart-define=DB=$CDATA_TEST_DB
)

FILES=(type_fidelity smoke)
failed=0

# 窗口被别的窗口完全挡住时，macOS 停掉这个视图的刷新信号，live binding 的 pump() 等不到帧，
# 测试就无声地卡住（CPU 为 0，可以卡几十分钟）。flutter 自己的「把 app 调到前台」总是失败
# （Failed to foreground app; open returned 1），所以这里等 app 起来后自己激活。
# 进程出现时窗口不一定已经建好，头 15 秒每秒激活一次。跑测试期间别把窗口盖住。
activate_when_launched() {
  for i in {1..600}; do
    if pgrep -x CData >/dev/null; then
      for j in {1..15}; do
        osascript -e 'tell application id "com.ckales.cdata" to activate' >/dev/null 2>&1 || true
        sleep 1
      done
      return
    fi
    sleep 0.5
  done
}

for name in $FILES; do
  echo "=== $name ==="
  killall CData 2>/dev/null || true
  # 等旧进程真退出，免得下面激活到正在退出的那一个
  while pgrep -x CData >/dev/null; do sleep 0.2; done
  activate_when_launched &
  activator=$!
  if ! flutter test "integration_test/${name}_test.dart" -d macos $DEFINES; then
    failed=1
  fi
  kill $activator 2>/dev/null || true
done

exit $failed
