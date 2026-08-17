#!/usr/bin/env bash
# ============================================================================
# 一键打包脚本：产出「按 ABI 拆分 + 通用」两种 release APK
#
# 用法：
#   ./tool/build-apk.sh              # 以 pubspec.yaml 版本号打包
#   ./tool/build-apk.sh -v 1.2.3     # 以指定版本号打包
#   ./tool/build-apk.sh -c           # 先清理再打包
#   ./tool/build-apk.sh -v 1.2.3 -c  # 清理后以指定版本号打包
#   ./tool/build-apk.sh -h           # 查看帮助
#
# 产物输出到 dist/ 目录：
#   jellfin-<version>-universal.apk  （兼容大包，所有 ABI 合在一起）
#   jellfin-<version>-arm64-v8a.apk  （arm64 小包，推荐）
#   jellfin-<version>-armeabi-v7a.apk（arm32 小包）
#   jellfin-<version>-x86_64.apk     （x86 模拟器包）
#
# 发布策略：
#   - 两次构建全部成功后才写进 dist/，中途失败/中断时 dist/ 里的上一版可用产物
#     保持不动——半套新包比一套旧包更危险（版本还对不上）。
#   - 签名校验不通过不发布。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

# ── 解析参数 ─────────────────────────────────────────────────────────────────
CLEAN_FIRST=false
CUSTOM_VERSION=""

usage() {
    grep -E "^#  " "$0" | sed 's/^#  //'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version) CUSTOM_VERSION="$2"; shift 2 ;;
        -c|--clean)   CLEAN_FIRST=true; shift ;;
        -h|--help)    usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

# ── 加载环境 ─────────────────────────────────────────────────────────────────
source "$SCRIPT_DIR/env.sh"

# ── 确定版本号 ───────────────────────────────────────────────────────────────
if [[ -n "$CUSTOM_VERSION" ]]; then
    VERSION="$CUSTOM_VERSION"
    # 同时更新 pubspec.yaml 中的版本号（只改 version 行，不改 description）
    # 确保版本号符合 pubspec 规范（如 1.2.3+4）
    if echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$'; then
        # 如果没带 build number，自动加 +1
        if ! echo "$VERSION" | grep -q '+'; then
            VERSION="${VERSION}+1"
        fi
        echo "==> 更新 pubspec.yaml 版本号到 $VERSION"
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i '' -E "s/^version: .*/version: $VERSION/" pubspec.yaml
        else
            sed -i -E "s/^version: .*/version: $VERSION/" pubspec.yaml
        fi
    else
        echo "错误：版本号格式无效，请使用 x.y.z 或 x.y.z+build (如 1.2.3+4)"
        exit 1
    fi
fi

# 从 pubspec.yaml 读取版本号（不含 build number）
VERSION=$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}' | cut -d+ -f1)
BUILD_NUM=$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}' | grep -o '\+[0-9]\+' | tr -d '+' || echo "1")

echo "=========================================="
echo "  Jellfin Flutter 打包脚本"
echo "  版本: $VERSION (build $BUILD_NUM)"
echo "  Flutter: $(flutter --version 2>/dev/null | head -1)"
echo "=========================================="
echo ""

# ── 可选清理 ─────────────────────────────────────────────────────────────────
if [[ "$CLEAN_FIRST" == true ]]; then
    echo "==> 清理旧构建产物..."
    flutter clean 2>/dev/null || true
    echo "    完成"
    echo ""
fi

# ── 目录与临时文件 ───────────────────────────────────────────────────────────
OUT="$PROJECT_DIR/dist"
APK_DIR="build/app/outputs/flutter-apk"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# ── 配置 Gradle 参数（加速构建，减小内存） ─────────────────────────────────────
# 堆大小可用 GRADLE_JVM_HEAP 覆盖：本机只有 8G 且 swap 常年吃满，2g 堆跑到第二次
# 构建（--split-per-abi）时 daemon 会被 OOM killer 干掉（rss 冲到 2.7G）。内存紧张
# 时用 GRADLE_JVM_HEAP=1400m 打包。
GRADLE_HEAP="${GRADLE_JVM_HEAP:-2g}"
GRADLE_OPTS="-Dorg.gradle.jvmargs=-Xmx$GRADLE_HEAP -Dorg.gradle.parallel=true -Dorg.gradle.caching=true"

# ── 第一步：通用包（所有 ABI，兼容性最好） ─────────────────────────────────────
echo ""
echo "==> [1/2] 通用包（所有 ABI，兼容性最好）"
echo "    ${OUT}/jellfin-${VERSION}-universal.apk"
echo ""

if ! flutter build apk --release \
    --no-tree-shake-icons \
    --target-platform android-arm,android-arm64,android-x64 \
    $GRADLE_OPTS 2>&1 | \
    while IFS= read -r line; do echo "    $line"; done; then
    echo ""
    echo "错误：通用包构建失败，请检查错误信息。dist/ 目录未更新。"
    exit 1
fi

cp "$APK_DIR/app-release.apk" "$STAGE/jellfin-$VERSION-universal.apk"
echo "  ✓ 通用包构建完成"

# 两次构建之间放掉 daemon：它会攥着上一次构建的整个堆不还，紧接着的第二次构建
# 因此更容易被 OOM killer 选中（本机实测）。冷启动多花十几秒，换来能打出全套包。
echo "==> 释放 Gradle daemon（降低第二次构建的内存峰值）"
(cd android && ./gradlew --stop >/dev/null 2>&1) || true

# ── 第二步：按 ABI 拆分（小包，体积约为通用包的 1/3） ─────────────────────────
echo ""
echo "==> [2/2] 按 ABI 拆分（小包）"
echo "    ${OUT}/jellfin-${VERSION}-arm64-v8a.apk"
echo "    ${OUT}/jellfin-${VERSION}-armeabi-v7a.apk"
echo "    ${OUT}/jellfin-${VERSION}-x86_64.apk"
echo ""

if ! flutter build apk --release --split-per-abi $GRADLE_OPTS 2>&1 | \
    while IFS= read -r line; do echo "    $line"; done; then
    echo ""
    echo "错误：ABI 拆分包构建失败，请检查错误信息。dist/ 目录未更新。"
    exit 1
fi

for abi in arm64-v8a armeabi-v7a x86_64; do
    # 缺件必须报错：原先的 if [[ -f ]] 会把「某个 ABI 没产出」静默跳过，
    # 最后只发布三个包却仍打印成功——半套包比构建失败更难发现。
    if [[ ! -f "$APK_DIR/app-$abi-release.apk" ]]; then
        echo ""
        echo "错误：缺少 $abi 包（$APK_DIR/app-$abi-release.apk 不存在）。dist/ 目录未更新。" >&2
        exit 1
    fi
    cp "$APK_DIR/app-$abi-release.apk" "$STAGE/jellfin-$VERSION-$abi.apk"
    echo "  ✓ $abi 包完成"
done

# ── 完整性闸门：四件套必须齐全（universal + 三个 ABI） ─────────────────────────
echo ""
echo "==> 完整性校验（universal / arm64-v8a / armeabi-v7a / x86_64）"
MISSING=false
for name in universal arm64-v8a armeabi-v7a x86_64; do
    f="$STAGE/jellfin-$VERSION-$name.apk"
    # APK 小于 1MB 基本可以断定是产出异常（正常最小的 arm32 包 28M 上下）。
    if [[ ! -s "$f" ]] || [[ "$(stat -c%s "$f")" -lt 1048576 ]]; then
        printf "  %-40s ✗  缺失或异常\n" "jellfin-$VERSION-$name.apk"
        MISSING=true
    else
        printf "  %-40s ✓  %s\n" "jellfin-$VERSION-$name.apk" "$(ls -lh "$f" | awk '{print $5}')"
    fi
done
if [[ "$MISSING" == true ]]; then
    echo ""
    echo "四个版本未全部产出，未发布到 $OUT/" >&2
    exit 1
fi

# ── 第三步：签名校验 ──────────────────────────────────────────────────────────
SIGNER=$(ls "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | tail -1)
if [[ -z "$SIGNER" ]]; then
    echo "错误：找不到 apksigner（build-tools 未安装或路径不对）"
    echo "  ANDROID_HOME=$ANDROID_HOME"
    exit 1
fi

echo ""
echo "==> 签名校验"
ALL_OK=true
for f in "$STAGE"/*.apk; do
    basename=$(basename "$f")
    if "$SIGNER" verify "$f" >/dev/null 2>&1; then
        printf "  %-40s ✓  OK\n" "$basename"
    else
        printf "  %-40s ✗  FAIL\n" "$basename"
        ALL_OK=false
    fi
done

if [[ "$ALL_OK" != true ]]; then
    echo ""
    echo "签名校验失败，未发布到 $OUT/" >&2
    exit 1
fi

# ── 第四步：发布到 dist/ ──────────────────────────────────────────────────────
mkdir -p "$OUT"
mv -f "$STAGE"/*.apk "$OUT"/

echo ""
echo "=========================================="
echo "  打包完成！产物："
echo "=========================================="
echo ""
for f in "$OUT"/*.apk; do
    basename=$(basename "$f")
    size=$(ls -lh "$f" | awk '{print $5}')
    printf "  %-6s  %s\n" "$size" "$basename"
done
echo ""
echo "  安装："
echo "    adb install dist/jellfin-${VERSION}-arm64-v8a.apk"
echo ""

# ── 第五步：清理旧版本（保留最近 3 个版本） ────────────────────────────────────
echo "==> 清理旧版本（保留最近 3 个版本）"
OLD_COUNT=$(ls -1 "$OUT"/*.apk 2>/dev/null | wc -l)
# 按 mtime 排序，保留最新 3 个版本（每个版本 4 个 APK = 12 个文件）
MAX_FILES=12
if [[ "$OLD_COUNT" -gt "$MAX_FILES" ]]; then
    ls -1t "$OUT"/*.apk 2>/dev/null | tail -n +$((MAX_FILES + 1)) | while read -r f; do
        rm -f "$f"
        echo "  删除旧版本: $(basename "$f")"
    done
fi
echo "  完成"