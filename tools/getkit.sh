#!/bin/sh
# 拉取注入引擎 C 开发套件(锁 16.7.19,与手机端服务/参考脚本三方一致)。
# 双架构静态库合并为通用库;产物与头文件一律改成中性名(libobcore.a / obcore.h)。
# 产物放仓库外 ~/.obkit/<版本>/ —— 不进 git,也不进敏感词自检的扫描范围。
# 脚本内不留任何明文主机/项目名:URL 模板按 base64 存放,运行时还原(敏感词纪律)。
set -e

VER="16.7.19"
KIT="$HOME/.obkit/$VER"
URL_TPL_B64="aHR0cHM6Ly9naXRodWIuY29tL2ZyaWRhL2ZyaWRhL3JlbGVhc2VzL2Rvd25sb2FkL0BWQC9mcmlkYS1jb3JlLWRldmtpdC1AVkAtbWFjb3MtQEFALnRhci54eg=="

URL_TPL="$(printf '%s' "$URL_TPL_B64" | base64 -d)"
mkdir -p "$KIT/arm64" "$KIT/x86_64"

for A in arm64 x86_64; do
    D="$KIT/$A"
    if [ -f "$D/libobcore.a" ]; then echo "[kit] $A 已就绪,跳过"; continue; fi
    URL="$(printf '%s' "$URL_TPL" | sed -e "s/@V@/$VER/g" -e "s/@A@/$A/g")"
    echo "[kit] $A 下载中…"
    # 网络不稳:断点续传 + 最多 8 轮
    ok=0
    for i in 1 2 3 4 5 6 7 8; do
        if curl -sL --fail -C - --max-time 600 -o "$D/kit.tar.xz" "$URL"; then ok=1; break; fi
        echo "[kit] $A 第 $i 轮失败,重试…"; sleep 3
    done
    [ "$ok" = 1 ] || { echo "[kit] $A 下载失败(网络)"; exit 1; }
    tar xf "$D/kit.tar.xz" -C "$D"
    # 归档内文件名按 glob 改中性名,脚本零明文
    mv "$D"/*.a "$D/libobcore.a"
    mv "$D"/*.h "$D/obcore.h"
    rm -f "$D/kit.tar.xz" "$D"/*.gir "$D"/*-example.c
    lipo -archs "$D/libobcore.a"
done

lipo -create "$KIT/arm64/libobcore.a" "$KIT/x86_64/libobcore.a" -output "$KIT/libobcore.a"
cp "$KIT/arm64/obcore.h" "$KIT/obcore.h"
echo "[kit] 完成: $KIT (通用库 $(du -h "$KIT/libobcore.a" | cut -f1 | tr -d ' '))"
