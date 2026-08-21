#!/bin/bash
# ============================================================
#  OpenJDK 原生 Windows 构建（在 Cygwin bash 中运行）
#  调用方式（Git Bash 侧）:
#     bash .workbuddy/run-cygwin-build.sh
#  或直接：
#     /c/cygwin64/bin/bash.exe -c 'export PATH=/usr/bin:/bin:...; cd /cygdrive/d/project/jdk; bash .workbuddy/build-jdk-windows.sh'
#
#  注意: 路径一律用 Cygwin 风格 /cygdrive/c/...，不要 C:\...
# ============================================================
set -e
cd /cygdrive/d/project/jdk

# ============================================================
#  关键修复：剔除 WorkBuddy 的 BASH_ENV 注入
#  WorkBuddy 把 BASH_ENV 指向 safe-bin/safe-delete-bash-env.sh，
#  该脚本把 `rm` 重定义为调用 broken safe-bin/rm 的【shell函数】。
#  后果链：
#   1) 我的 `rm -rf build/...` 实际不删除任何文件（stale 目录残留）
#   2) configure 的 conftest 清理失败 → 误报 "C compiler cannot create executables"
#   3) config.status 里的 rm 失败 → "could not create spec.gmk"
#  必须在做任何事之前 unset，否则子 shell（configure/config.status）会重新注入。
# ============================================================
unset BASH_ENV
unset -f rm 2>/dev/null

# --- 清理 PATH ---
# 剔除 safe-bin / app.asar 路径，并把 Cygwin 工具链提到最前，避免 Msys 同名程序误判。
# 保留 PortableGit 等无空格路径（configure 需要 git 做版本探测）。
export PATH=$(echo "$PATH" | tr ':' '\n' \
  | grep -vi 'safe-bin' \
  | grep -vi 'app.asar' \
  | tr '\n' ':' | sed 's/:$//')
export PATH="/usr/bin:/bin:/usr/local/bin:/cygdrive/c/WINDOWS/system32:/cygdrive/c/WINDOWS:/cygdrive/c/WINDOWS/System32/Wbem:$PATH"
export PATH="$PATH:/cygdrive/c/Users/EDY/.workbuddy/binaries/PortableGit/versions/1.2.0/mingw64/bin"

echo "==> [0] 环境已清理: BASH_ENV='${BASH_ENV}'; rm 解析为: $(which rm)"

# boot JDK: 主人已下载 JDK 27 EA（源码 HEAD 约 JDK 28，27 为 N-1，合规）
BOOT_JDK="/cygdrive/c/Users/EDY/.jdks/openjdk-ea-27-ea+34-2321"
FREETYPE_ARG="--with-freetype=bundled"

echo "==> [1/3] configure ..."
bash configure \
  --with-boot-jdk="$BOOT_JDK" \
  --with-toolchain-version=2022 \
  --disable-warnings-as-errors \
  $FREETYPE_ARG

echo "==> [2/3] make images (首次约 30-60 分钟) ..."
make images

echo "==> [3/3] 验证 + 生成 IDEA 工程 ..."
JDK_IMG=$(ls -d build/*/images/jdk 2>/dev/null | head -1)
"$JDK_IMG/bin/java" -version
# 删掉旧的手写只读 jdk.iml，避免与官方 idea.sh 生成的工程冲突
rm -f jdk.iml
# idea.sh 需要 ANT_HOME（Windows 下不会自动探测）
export ANT_HOME="$(cd .workbuddy/apache-ant-* 2>/dev/null && pwd)"
if [ ! -f "$ANT_HOME/lib/ant.jar" ]; then
  echo "WARN: ANT_HOME 未找到 ant.jar，idea.sh 会失败"
fi
bash bin/idea.sh
echo "完成。用 IDEA 打开本目录，Project SDK 指向 $JDK_IMG，"
echo "在 Ant 面板(来自 make/ide/idea/jdk/build.xml)里跑构建目标即可。"
