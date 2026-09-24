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

for name in $FILES; do
  echo "=== $name ==="
  killall CData 2>/dev/null || true
  if ! flutter test "integration_test/${name}_test.dart" -d macos $DEFINES; then
    failed=1
  fi
done

exit $failed
