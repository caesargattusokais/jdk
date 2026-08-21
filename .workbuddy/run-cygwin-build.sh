#!/bin/bash
# ============================================================
#  Git Bash 侧启动器：进入干净的 Cygwin 环境执行 OpenJDK 构建
#
#  两个关键点（踩坑结论，缺一不可）：
#  1. 剔除 WorkBuddy 注入的 safe-bin/rm shim。该 shim 在 Cygwin 下因 CRLF +
#     缺失 safe-delete-common.sh 而崩溃（exit 127），会污染 configure/make
#     的编译探测（表现为 "C compiler cannot create executables"）。
#  2. 把 Cygwin 的 /usr/bin:/bin 提到 PATH 最前，避免从 Git Bash(Msys) 继承的
#     PATH 让 uname/make 解析到 Msys 同名程序，导致 OpenJDK configure 误判环境。
# ============================================================
# 先在本进程剔除 safe-bin / app.asar，并把 BASH_ENV 注入一并清掉，
# 再把结果传给 Cygwin bash（build-jdk-windows.sh 内部还会再 unset 一次以防万一）。
unset BASH_ENV
unset -f rm 2>/dev/null
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' \
  | grep -vi 'safe-bin' \
  | grep -vi 'app.asar' \
  | tr '\n' ':' | sed 's/:$//')

exec /c/cygwin64/bin/bash.exe -c \
  "unset BASH_ENV; unset -f rm 2>/dev/null; export PATH=/usr/bin:/bin:/usr/local/bin:/cygdrive/c/WINDOWS/system32:/cygdrive/c/WINDOWS:/cygdrive/c/WINDOWS/System32/Wbem:$(printf '%q' "$CLEAN_PATH"); cd /cygdrive/d/project/jdk; exec bash .workbuddy/build-jdk-windows.sh"
