# TorchOffOnSleep

一个 iOS 越狱 tweak：屏幕已熄灭且手电筒开启时，按一次侧键（锁屏键）**只关闭手电筒、屏幕保持熄灭**；再按一次才正常亮屏。其余所有场景与原生行为一致。

- 注入目标：`com.apple.SpringBoard`（仅此一个进程）
- 无设置界面、无运行时配置、不写持久化状态、不注册守护进程
- 目标系统：iOS 17.x。依赖的私有符号在 iOS 17.1 (21B80, iPhone16,2) 的 dyld shared cache 中已逐一确认存在
- **验收状态：未做真机运行时验证。** 已完成的验证只有构建、包结构、二进制 slice、固件符号契约（静态）与反编译复核；设备上的实际行为未验证，详见文末「已知限制」第 1 条

## 功能

### 方案 A 语义（默认）

1. 屏幕已熄灭、手电筒开启时，按一次侧键 → **只关闭手电筒，屏幕保持熄灭**（不进入锁屏界面）
2. 此时再按一次侧键 → 正常亮屏进入锁屏界面，与未安装本插件的设备一致
3. 屏幕点亮时按侧键 → 原生息屏，**不碰手电筒**

这里「屏幕已熄灭」指**系统自身判定"应当亮屏"的状态**，包含屏幕完全熄灭与锁屏界面变暗两种情况。插件刻意不自行实现屏幕状态判定，原因见「技术原理」。

### 全场景行为

| 场景 | 行为 |
|---|---|
| 屏幕已熄灭 + 手电筒开启，按一次侧键 | 只关闭手电筒，屏幕保持熄灭 |
| 上一行之后，再按一次侧键 | 正常亮屏进入锁屏界面（与原生一致） |
| 屏幕点亮时（锁屏 / 主屏幕 / 前台应用内）按侧键 | 原生息屏；手电筒保持开启，不被关闭 |
| 屏幕已熄灭 + 手电筒已关闭，按侧键 | 原生亮屏进入锁屏界面（插件不干预） |
| 常亮显示（AOD）处于显示态 + 手电筒开启，按侧键 | 手电筒保持开启，与未安装插件一致 |
| 无闪光灯设备（iPad、iPod touch） | 侧键行为完全不变，零干预、零日志 |
| 屏幕已熄灭 + 手电筒开启时双击侧键 | 相机按原生行为打开；第一次按压关灯且不亮屏，不阻碍第二次按压被识别为双击 |
| 长按侧键（SOS 紧急联络）、长按 + 音量键（强制重启） | 原生行为，插件不拦截、不干扰 |

补充两点：

- 手电筒「是否开启」以系统手电筒通道 `-[SBUIFlashlightController level] > 0` 为准。无论手电筒是从锁屏快捷按钮、控制中心还是其它官方入口开启的，判定都与该入口一致。
- 关灯动作同样经由系统自己的手电筒控制通道 `-[SBUIFlashlightController turnFlashlightOffForReason:]` 完成，因此锁屏按钮、控制中心、灵动岛/状态栏的手电筒状态始终保持一致，不会出现「灯已灭但界面仍显示开启」或反之。

## 产物线与适用环境

`out/` 下有两条产物线，**按你设备的越狱环境二选一，不要装到同一个环境**：

| 产物 | 适用环境 | deb 内 dylib 路径 | Architecture | 二进制 slice |
|---|---|---|---|---|
| `out/TorchOffOnSleep_1.0.0_roothide_arm64e.deb` | roothide / bootstrap 环境 | `Library/MobileSubstrate/DynamicLibraries/` | `iphoneos-arm64e` | 仅 `arm64e` |
| `out/TorchOffOnSleep_1.0.0_rootless_arm64.deb` | rootless 环境 | `var/jb/Library/MobileSubstrate/DynamicLibraries/` | `iphoneos-arm64` | `arm64` + `arm64e` |

**为什么不要装到同一个环境**：两条线的包 id 相同（`com.tune.torchoffonsleep`），同一个环境里装两条会互相覆盖；且两条线的安装根不同，装错线不会按预期加载。请按设备实际所用的越狱环境选一条。

两条线目前都只做到静态验收（构建、包结构、slice、固件符号契约），均未做设备运行时验证；其中 rootless 线未验证 SpringBoard 在 rootless 环境下是否真的加载它（见「已知限制」第 5 条）。

## 安装

把对应 deb 传到设备（scp、文件管理器等方式均可），在设备上以 root 执行。

roothide / bootstrap 环境：

```bash
dpkg -i TorchOffOnSleep_1.0.0_roothide_arm64e.deb
killall -9 SpringBoard
```

rootless 环境：

```bash
dpkg -i TorchOffOnSleep_1.0.0_rootless_arm64.deb
killall -9 SpringBoard
```

`killall -9 SpringBoard` 即 respring；如果你的环境里有 `sbreload`，也可以用它代替。

## 卸载

在设备上以 root 执行：

```bash
dpkg -r com.tune.torchoffonsleep
killall -9 SpringBoard
```

卸载即完全恢复原生行为：插件不写任何持久化状态、不写配置文件、不注册守护进程，dylib 随包删除后无残留。

若 SpringBoard 因此无法启动，进安全模式，或经 SSH 删除 dylib 后 respring。

roothide / bootstrap 环境：

```bash
rm -f /Library/MobileSubstrate/DynamicLibraries/TorchOffOnSleep.dylib
killall -9 SpringBoard
```

rootless 环境：

```bash
rm -f /var/jb/Library/MobileSubstrate/DynamicLibraries/TorchOffOnSleep.dylib
killall -9 SpringBoard
```

## 从源码构建

唯一认可的正式打包入口是 `scripts/build_packages.sh`：它依次构建 roothide 与 rootless 两条线，核对产物名与包头，净化宿主元数据，并把 deb 收敛输出到 `out/`。在仓库根目录执行：

```bash
THEOS=/opt/theos ./scripts/build_packages.sh
```

前置条件：theos 位于 `/opt/theos`（含 `vendor/mod/roothide` 与 `vendor/mod/rootless`），系统有 `make`、`dpkg-deb`、`find`、`sed`、`mktemp`、`cp`、`kill`、`sleep`（脚本启动时会自检，缺一项即报错退出）。

可用环境变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `THEOS` | `/opt/theos` | theos 根目录 |
| `ENABLE_ROOTFUL` | 不设置 | 置 `1` 时额外构建 rootful 线（`THEOS_PACKAGE_SCHEME` 显式为空），默认不构建 |
| `DSC_PATH` | 空 | 提供固件 dyld shared cache 路径时，构建前先跑固件符号门禁；未提供则跳过（不算失败）。需要 `ipsw` 与 `nm` |
| `LOCK_WAIT_SECONDS` | `120` | 等待构建锁的最长秒数 |

带符号门禁的完整构建示例：

```bash
DSC_PATH=/path/to/dyld_shared_cache_arm64e THEOS=/opt/theos ./scripts/build_packages.sh
```

符号门禁也可以单独运行：

```bash
DSC_PATH=/path/to/dyld_shared_cache_arm64e bash scripts/verify_symbols.sh
```

### 编译期开关

两个开关都用 `#ifndef` 包裹，可在 `make` 命令行用 `TorchOffOnSleep_CFLAGS` 覆盖，无需改源码：

| 开关 | 默认 | 作用 |
|---|---|---|
| `TORCH_OFF_SUPPRESS_WAKE` | `1` | `1` = 方案 A（不调 `%orig`，屏幕保持熄灭）；`0` = 亮屏并关灯。影响主 hook 与降级 2 |
| `TORCH_OFF_ENABLE_LOG` | `0` | `0` = 零日志；`1` = 用 `os_log` 打印拦截命中、关灯调用与降级层号（排障用） |

注意：make 命令行的 `TorchOffOnSleep_CFLAGS` 会整体覆盖 Makefile 里的取值，重新指定时必须把 `-fobjc-arc` 一起带上。示例（构建「亮屏并关灯」语义的 rootless 包）：

```bash
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless TorchOffOnSleep_CFLAGS="-fobjc-arc -DTORCH_OFF_SUPPRESS_WAKE=0"
```

### 构建后自检

```bash
dpkg-deb -f out/TorchOffOnSleep_1.0.0_roothide_arm64e.deb Package Version Architecture
dpkg-deb -f out/TorchOffOnSleep_1.0.0_rootless_arm64.deb Package Version Architecture
rm -rf /tmp/torchoff-rootless && dpkg-deb -R out/TorchOffOnSleep_1.0.0_rootless_arm64.deb /tmp/torchoff-rootless
lipo -archs /tmp/torchoff-rootless/var/jb/Library/MobileSubstrate/DynamicLibraries/TorchOffOnSleep.dylib
find /tmp/torchoff-rootless \( -name .DS_Store -o -name '._*' -o -name __MACOSX \) -print
```

判据：roothide 线 `Architecture: iphoneos-arm64e`、rootless 线 `iphoneos-arm64`；rootless 线的 dylib 应同时含 `arm64` 与 `arm64e` 两个 slice；最后一条 `find` 的输出应为空。

## 已知限制

1. **无真机运行时验证。** 构建、包结构、二进制 slice、固件符号契约（iOS 17.1 (21B80, iPhone16,2) 的 dyld shared cache，17/17 命中）与反编译复核都做了，但设备上的实际行为未验证。本 README 不宣称功能已验证通过。
2. **淡出到锁屏的约 0.3 s 窗口内连按两次**：原生会逆转淡出、让屏幕回来；本插件会改为关灯并保持淡出。v1 不处理这个差异。
3. **降级 3 无法抑制亮屏**：当 `_performWake` 与 `consumeInitialPressDown` 都不可用时，最后会降级到 hook `-[SBLockHardwareButtonActions performSinglePressAction]`；该点位于松手阶段、亮屏早已发生，语义退化为「亮屏 + 关灯」，`TORCH_OFF_SUPPRESS_WAKE` 在这一层无效。
4. **AOD 显示态不关灯**：常亮显示处于显示态时，系统本身不执行亮屏动作，插件继承该语义，同样不关灯（这一点已写入行为契约）。
5. **rootless 线只验到包结构与 slice**：未验证 rootless 环境下 SpringBoard 是否真的加载它。
6. **17.0–17.4 符号稳定性未在其它小版本上验证**：三层降级加 `respondsToSelector:` 判空是对付符号缺失的唯一防线。
7. **`homeButtonType == 2` 对应哪种设备形态未确认**：已用「父类与子类都 hook」规避，但若某版本引入第三种实现，仍会漏。

## 技术原理

### hook 点

插件只 hook 唤醒路径上的一个方法：

- `-[SBSleepWakeHardwareButtonInteraction _performWake]`

同时对其子类 `SBDoubleClickSleepWakeHardwareButtonInteraction` 也装一份：反编译确认子类覆盖了 `_performWake`，而 Substrate 的 hook 替换的是具体类的 IMP——只 hook 父类时，设备实例化子类会让父类被 hook 的 IMP 被绕过，插件静默失效。

命中判据只有一个：`SBUIFlashlightController` 存在、`deviceSupportsFlashlight` 为真、`level > 0`。未命中时直接 `%orig`，走原生逻辑。

### 为什么「屏幕已熄灭」这个条件由系统前置判定免费继承

`_performWake` 位于系统全部前置判定之后：`consumeInitialPressDown` 已判过 `screenIsDim`（AOD 开启时还判了 `backlightState != 3`），`_performWake` 开头又判了 `shouldNeverLock` / `!screenIsDim` / `caseIsEnabledAndLatched`。能执行到 `_performWake`，就等于「系统已经决定要亮屏」。因此插件刻意不自行实现任何屏幕状态判定，直接复用系统在该按压时刻的既有判定结果——重复判断只会与系统语义（尤其是 AOD 相关分支）产生漂移。

### 其它实现要点

- **补 `setInhibitNextSinglePressUp:YES`**：原生 `_performWake` 在亮屏成功后会把该标志置 YES，使松手阶段的 `consumeSinglePressUp` 变成空操作。方案 A 不调 `%orig`，这个赋值就不会发生，松手时会误走 `_performSleep()`（表现为多一声锁屏音加一次锁屏动画），所以显式复用它。
- **关灯走系统通道**：`-[SBUIFlashlightController turnFlashlightOffForReason:]`，保证各官方入口的手电筒状态一致。
- **注入过滤**：`TorchOffOnSleep.plist` 只注入 `com.apple.SpringBoard`，不碰其它进程。
- **三层降级装填**：`_performWake` → `consumeInitialPressDown` → `performSinglePressAction`，按符号可用性择一安装；三层全无则什么都不装，侧键行为与原生一致。装填在主队列首轮完成（早于任何 HID 事件被处理），降级判断不在按压路径上临时探测。
- **无运行时配置**：没有设置界面、没有配置文件、没有守护进程，只有两个编译期开关。

### 文档索引

| 文档 | 内容 |
|---|---|
| `docs/openspec/changes/torch-off-on-lock-press/specs/torch-off-on-lock-press/spec.md` | 行为契约（delta spec） |
| `docs/superpowers/specs/2026-09-21-torch-off-on-sleep-design.md` | 技术设计（含 §8 已知限制） |
| `docs/RE-notebook.md` | 逆向笔记（侧键控制流、xref 证据、符号地址、hook 点取舍） |

### 仓库结构

```
Makefile                          theos 构建定义（ARCHS 按 scheme 分流）
control                           deb 元数据（Package: com.tune.torchoffonsleep）
TorchOffOnSleep.plist             注入过滤（仅 com.apple.SpringBoard）
Tweak.xm                          全部插件逻辑（单文件）
scripts/build_packages.sh         统一打包入口（两条产物线 + 符号门禁）
scripts/verify_symbols.sh         固件符号契约门禁（17 个符号）
out/                              构建产物（两个 deb）
docs/                             行为契约、技术设计、逆向笔记
```
