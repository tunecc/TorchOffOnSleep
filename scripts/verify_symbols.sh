#!/bin/bash
# =============================================================================
# scripts/verify_symbols.sh — 固件符号契约门禁（Task 4.1，Design Doc §6.5）
#
# 把「插件依赖的私有符号在目标固件里确实存在」从人工记忆变成可执行门禁。
#
# 断言清单（20 个）：
#   - openspec design.md「已确认可用的符号」表全部 16 行
#   - + Tweak.xm 降级 3 真实依赖的
#     -[SBLockHardwareButtonActions performSinglePressAction]
#     （该表未列此条，但 Tweak.xm 段⑥ TorchOffSinglePress group 在用）
#   - + 最终代码审查 I1 / I2 补入的 3 条：
#       -[SBSleepWakeHardwareButtonInteraction backlightController]
#       +[SBBacklightController sharedInstanceIfExists]
#       _OBJC_CLASS_$_SBSleepWakeHardwareButtonInteraction
#     前两条是屏幕判定的直接依赖：第一条是降级 2 屏幕判定链的第一环，第二条是
#     降级 3 屏幕守卫取实例的唯一入口（SBLockHardwareButtonActions 没有
#     backlightController 方法）。它们原先都不在门禁里——缺了会各自让对应降级层
#     静默空转，而门禁仍可能全绿，等于给虚假保证。
#     第三条与既有的子类 _OBJC_CLASS_$_ 断言成对：I1 加固后第 1、2 层的父类装填
#     同样依赖 %c() 对父类的查找，父类整体消失会让父类那一份 hook 静默不装。
#   其中 3 条是子类符号（SBDoubleClickSleepWakeHardwareButtonInteraction，
#   Design Doc §3.0 补入；只 hook 父类会在子类设备上静默失效）：
#     _OBJC_CLASS_$_SBDoubleClickSleepWakeHardwareButtonInteraction
#     -[SBDoubleClickSleepWakeHardwareButtonInteraction _performWake]
#     -[SBDoubleClickSleepWakeHardwareButtonInteraction consumeInitialPressDown]
#
# 实现方式（Design Doc §6.5，已实测）——两步，不要用 ipsw dyld symaddr：
#   1) ipsw dyld extract --objc 把目标 dylib 从 DSC 提取到临时目录。
#      --objc 才会把 ObjC 方法符号写进 symtab，nm 才查得到。
#   2) nm 每库只落盘一次，再 grep -qF 逐个查（毫秒级）。
#   不用 ipsw dyld symaddr 的原因：它每次调用都要重新解析 12.4M 条符号表，
#   单符号就要数十秒，20 个串行会跑十几分钟。
#
# 用法：
#   DSC_PATH=/path/to/dyld_shared_cache_arm64e bash scripts/verify_symbols.sh
#
# DSC_PATH 未提供（或为空串）→ 打印提示并 exit 0（跳过而非失败）。
# 这样 Task 4.3 把本脚本接进 scripts/build_packages.sh 之后，没有固件的
# 机器也能正常打包。
#
# 退出码：0 = 全部命中，或 DSC_PATH 未提供而跳过；
#         1 = 有符号缺失 / DSC 不可用 / 依赖命令缺失。
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# DSC_PATH 缺省处理：跳过而非失败（接进构建后无固件机器必须能打包）
# 用 ${DSC_PATH:-} 而不是 $DSC_PATH，避免 set -u 下未定义变量直接退出。
# 显式传空串同样按跳过处理（构建脚本可能 export DSC_PATH=""）。
# ---------------------------------------------------------------------------
DSC_PATH="${DSC_PATH:-}"
if [ -z "$DSC_PATH" ]; then
    echo "[verify_symbols] 未提供 DSC_PATH，跳过固件符号契约校验"
    exit 0
fi

if [ ! -f "$DSC_PATH" ]; then
    echo "[verify_symbols] DSC_PATH 指向的文件不存在：$DSC_PATH" >&2
    exit 1
fi

for tool in ipsw nm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[verify_symbols] 缺少依赖命令：$tool" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# 临时目录：mktemp -d + trap 清理。不用字面 TMPDIR 作变量名，避免遮蔽
# mktemp 读取的 TMPDIR 环境变量语义。
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --cache 必须指向可写路径：DSC 挂载点是只读的，用 ipsw 默认缓存路径会
# read-only file system 失败，故把 addr-to-symbol 缓存放进临时目录。
CACHE="$WORK_DIR/dsc.a2s"

# DYLIB 参数必须传完整路径（/System/Library/PrivateFrameworks/...），
# 只传 SpringBoard.framework/SpringBoard 会报 image not found in cache。
# 进度输出重定向到 stderr，保持 stdout 只有最终结论行。
# 30 MB 的 SpringBoard 提取要几秒，属正常。
echo "[verify_symbols] DSC：$DSC_PATH" >&2
echo "[verify_symbols] 提取 SpringBoard 与 SpringBoardUI（--objc）..." >&2
ipsw dyld extract "$DSC_PATH" --cache "$CACHE" --objc --output "$WORK_DIR" \
    "/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard" >&2
ipsw dyld extract "$DSC_PATH" --cache "$CACHE" --objc --output "$WORK_DIR" \
    "/System/Library/PrivateFrameworks/SpringBoardUI.framework/SpringBoardUI" >&2

SB="$WORK_DIR/SpringBoard"
SBUI="$WORK_DIR/SpringBoardUI"
for f in "$SB" "$SBUI"; do
    if [ ! -f "$f" ]; then
        echo "[verify_symbols] 提取失败，未得到预期产物：$f" >&2
        exit 1
    fi
done

# nm 每库只跑一次并落盘，之后 grep 查文件。
# 两个理由：
#   1) 性能：20 次 nm 各自重解析符号表，不如一次 nm + 20 次 grep 文件；
#   2) 正确性：若写成 nm | grep -q 管道，grep -q 命中即退出会使 nm 收到
#      SIGPIPE 而非零退出，在 set -o pipefail 下整个管道判非零，把命中的
#      符号误报成缺失。落盘后 grep 文件没有管道，无此坑。
nm "$SB" > "$WORK_DIR/SpringBoard.syms"
nm "$SBUI" > "$WORK_DIR/SpringBoardUI.syms"

# ---------------------------------------------------------------------------
# 20 个符号断言。格式：<镜像>|<符号>，镜像 SB=SpringBoard，SBUI=SpringBoardUI。
# 用 here-doc 而不是 bash 数组：/bin/bash 是 3.2，set -u 下展开空数组会
# 直接报 unbound variable；字符串累加对所有 bash 版本都安全。
# 命中文案 "${hit}/${total}" 由循环计数得出，与本清单长度自动一致，不写死数字。
# 顺带说明：nm 输出里每个符号出现两次（t 本地符号 + ? 未定义），grep -qF
# 命中任意一行即可，重复不影响判定。
# ---------------------------------------------------------------------------
hit=0
total=0
missing=""
while IFS='|' read -r image symbol; do
    if [ -z "$symbol" ]; then continue; fi
    total=$((total + 1))
    if [ "$image" = "SBUI" ]; then
        symfile="$WORK_DIR/SpringBoardUI.syms"
    else
        symfile="$WORK_DIR/SpringBoard.syms"
    fi
    # grep -qF：符号名含 [ ]，按正则会变成字符类（- 后跟集合中任意单字符
    # 即命中），必须按字面匹配，否则缺失符号可能被误判为命中。
    if grep -qF -- "$symbol" "$symfile"; then
        hit=$((hit + 1))
    else
        missing="${missing}  - [${image}] ${symbol}"$'\n'
    fi
done <<'SYMBOL_LIST'
SB|-[SBSleepWakeHardwareButtonInteraction _performWake]
SB|-[SBSleepWakeHardwareButtonInteraction consumeInitialPressDown]
SB|-[SBSleepWakeHardwareButtonInteraction consumeSinglePressUp]
SB|-[SBSleepWakeHardwareButtonInteraction setInhibitNextSinglePressUp:]
SB|-[SBSleepWakeHardwareButtonInteraction fadeOutInProgressFromLockButtonWhileUnlocked]
SB|-[SBSleepWakeHardwareButtonInteraction backlightController]
SB|-[SBLockHardwareButtonActions performInitialButtonDownActions]
SB|-[SBLockHardwareButtonActions performSinglePressAction]
SB|-[SBBacklightController screenIsDim]
SB|-[SBBacklightController screenIsOn]
SB|-[SBBacklightController backlightState]
SB|+[SBBacklightController sharedInstanceIfExists]
SB|_OBJC_CLASS_$_SBSleepWakeHardwareButtonInteraction
SB|_OBJC_CLASS_$_SBDoubleClickSleepWakeHardwareButtonInteraction
SB|-[SBDoubleClickSleepWakeHardwareButtonInteraction _performWake]
SB|-[SBDoubleClickSleepWakeHardwareButtonInteraction consumeInitialPressDown]
SBUI|+[SBUIFlashlightController sharedInstance]
SBUI|+[SBUIFlashlightController deviceSupportsFlashlight]
SBUI|-[SBUIFlashlightController level]
SBUI|-[SBUIFlashlightController turnFlashlightOffForReason:]
SYMBOL_LIST

# ---------------------------------------------------------------------------
# 子类存在性单独显式断言（Design Doc §3.0 的关键前提）：第 1、2 层对
# SBDoubleClickSleepWakeHardwareButtonInteraction 也装 hook，靠 %c() 判空；
# 若固件里子类整体消失，DoubleClick group 会静默不装。该符号已计入上面的
# 20 个，这里只把结论显式打出来，不重复计数。
# 父类的 _OBJC_CLASS_$_SBSleepWakeHardwareButtonInteraction 同样在清单里
# （与子类成对），只是不单独再打一遍。
# ---------------------------------------------------------------------------
SUBCLASS_SYMBOL='_OBJC_CLASS_$_SBDoubleClickSleepWakeHardwareButtonInteraction'
if grep -qF -- "$SUBCLASS_SYMBOL" "$WORK_DIR/SpringBoard.syms"; then
    echo "[verify_symbols] 子类存在性：$SUBCLASS_SYMBOL 命中" >&2
else
    echo "[verify_symbols] 子类存在性断言失败：$SUBCLASS_SYMBOL 未找到" >&2
    if [ -z "$missing" ]; then
        missing="  - [SB] ${SUBCLASS_SYMBOL}"$'\n'
    fi
fi

if [ -n "$missing" ]; then
    echo "[verify_symbols] 缺失符号清单（命中 ${hit}/${total}）：" >&2
    printf '%s' "$missing" >&2
    echo "[verify_symbols] 符号契约校验未通过" >&2
    exit 1
fi

echo "${hit}/${total} 命中"
exit 0
