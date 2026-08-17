# source 本文件以配置 Flutter 开发环境（国内镜像 + SDK 路径）
#
# CI 上不要走这套本机路径：runner 已由 workflow 装好 Flutter/Android SDK，且国内镜像
# 从 GitHub 机房访问既慢又可能不通。因此检测到 CI=true 时整体跳过，让 tool/build-apk.sh
# 能在本机与 CI 两边复用同一套打包逻辑（四个 APK 的产出口径只有一份）。
if [[ "${CI:-}" == "true" ]]; then
    echo "[env.sh] CI 环境：沿用 runner 已配置的 Flutter/Android SDK，跳过本机路径与镜像设置"
else

# 同目录下的 flutter/ 是一份被裁剪过的残缺安装（缺 packages/flutter_tools 与 git 对象），
# 不要使用；flutter-3.44.9/ 是从官方镜像 tarball 完整解出的 stable SDK。
export FLUTTER_ROOT=/vol1/docker-data/flutter-sdk/flutter-3.44.9
export PATH="$FLUTTER_ROOT/bin:$PATH"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
# 网盘/内网流量不走代理；Flutter 工具链下载走镜像，无需代理
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
# 不要设 FLUTTER_PREBUILT_ENGINE_VERSION：tarball 自带的产物 stamp 用的是
# bin/internal/engine.version（引擎 git revision），强行钉成 content_hash 会让
# 所有 stamp 校验失配，触发整套引擎产物重新下载。

# Android 构建（flutter build apk）需要 SDK 路径；平台 36 由 Flutter 3.44.9 要求。
# SDK 实际安装在 /vol2/Android（空间大），通过软链接 ~/Android/Sdk 引用。
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

fi
