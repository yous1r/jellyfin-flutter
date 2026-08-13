# source 本文件以配置 Flutter 开发环境（国内镜像 + SDK 路径）
export FLUTTER_ROOT=/vol1/docker-data/flutter-sdk/flutter
export PATH="$FLUTTER_ROOT/bin:$PATH"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
# 网盘/内网流量不走代理；Flutter 工具链下载走镜像，无需代理
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
