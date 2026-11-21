#!/bin/zsh
# 逐页打开 iPhone 版并截图，存到 build-ios/shots/。只用命令行，不依赖能点屏幕的工具。
# 用法：Mobile/shots.sh [录音编号]    （不给编号就不截详情页）
cd "$(dirname "$0")/.."
U="${BEANPOD_SIM_ID:-$(xcrun simctl list devices available | grep "iPhone 16 Pro (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')}"
A=$(xcrun simctl get_app_container $U com.ffan008.badgepod.mobile app)
rsync -a --delete --exclude BeanPod.dSYM build-ios/sim/BeanPod.app/ "$A/"
mkdir -p build-ios/shots
shot() {
  local name=$1; shift
  xcrun simctl terminate $U com.ffan008.badgepod.mobile >/dev/null 2>&1
  # SHOT_ARGS 可以给每一页加同样的启动参数，比如 SHOT_ARGS="-appearance dark" 截深色
  xcrun simctl launch $U com.ffan008.badgepod.mobile "$@" ${=SHOT_ARGS} >/dev/null
  sleep ${WAIT:-4}
  xcrun simctl io $U screenshot "$PWD/build-ios/shots/$name.png" >/dev/null 2>&1
  sips -Z 900 "$PWD/build-ios/shots/$name.png" --out "$PWD/build-ios/shots/$name.png" >/dev/null
  echo "$name"
}
shot home
shot recordings -startTab recordings
shot knowledge -startTab knowledge
shot device -startTab device
shot settings -startTab device -showSettings YES
shot stage -previewStage YES
shot keep -previewKeep YES
if [ -n "$1" ]; then
  shot detail -openRecording $1
  shot transcript -openRecording $1 -startPane 文字稿
  shot rewrite -openRecording $1 -startPane 改写
fi
xcrun simctl terminate $U com.ffan008.badgepod.mobile >/dev/null 2>&1
