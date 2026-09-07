#!/bin/zsh
# build_dualpipe.sh — 编直传静态库(Release,双架构),供 App 链接。
# 用法(仓库根目录): ./tools/build_dualpipe.sh
# 直传库以 submodule 放在 Vendor/mac-dual-pipe(见 .gitmodules);产物在其 build/ 下(库内 ignore,不入库)。
# 产物: Vendor/mac-dual-pipe/build/Release/libmac-dual-pipe.a(头文件在 Vendor/mac-dual-pipe/src,见 pbxproj 引用)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBDIR="$ROOT/Vendor/mac-dual-pipe"
if [[ ! -d "$LIBDIR" ]]; then
    echo "子仓缺失: $LIBDIR(需 git submodule update --init)" >&2
    exit 1
fi
xcodebuild -project "$LIBDIR/mac-dual-pipe.xcodeproj" -target mac-dual-pipe \
    -configuration Release SYMROOT="$LIBDIR/build" build
ls -la "$LIBDIR/build/Release/libmac-dual-pipe.a"
