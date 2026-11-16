# TorchOffOnSleep

> 熄屏状态下按一次侧键，只关手电筒，不点亮屏幕。

一个 iOS 越狱插件（tweak），注入 SpringBoard，只修正一条按键路径：**用手电筒照明时熄屏，想关灯却被迫亮屏**。

- 屏幕已熄灭、手电筒开着时按一次侧键 → 手电筒关掉，屏幕保持黑屏
- 紧接着再按一次 → 正常亮屏进入锁屏界面
- 其余所有场景，与原生 iOS 完全一致

注入目标只有 `com.apple.springboard`；无设置界面、无配置文件、不写持久化状态、不注册守护进程。

## 它解决什么问题

原生 iOS 中，熄屏状态下按侧键一定亮屏。手电筒开着时想关灯，只能先把屏幕点亮，再解锁或回到控制中心——夜里这一下亮屏相当刺眼。

本插件只改这一条路径，其余按键语义（息屏、双击开相机、长按 SOS、长按加音量键强制重启）一律不动。

## 行为

### 默认行为

1. 屏幕已熄灭、手电筒开启，按一次侧键 → **只关闭手电筒，屏幕保持熄灭**，不进入锁屏界面
2. 保持该状态再按一次侧键 → 正常亮屏进入锁屏界面，与未安装插件的设备一致
3. 屏幕点亮时（锁屏 / 主屏幕 / 前台应用内）按侧键 → 原生息屏，**不碰手电筒**

上文的「屏幕已熄灭」指**系统自身判定「这次该亮屏了」的时刻**，既包括屏幕完全熄灭，也包括锁屏界面变暗。插件不自己判断屏幕状态，原因见「工作原理」。

### 全场景对照

| 场景 | 行为 |
|---|---|
| 屏幕已熄灭 + 手电筒开启，按一次侧键 | 只关闭手电筒，屏幕保持熄灭 |
| 上一行之后，再按一次侧键 | 正常亮屏进入锁屏界面（与原生一致） |
| 屏幕点亮时（锁屏 / 主屏幕 / 前台应用内）按侧键 | 原生息屏；手电筒保持开启，不被关闭 |
| 屏幕已熄灭 + 手电筒已关闭，按侧键 | 原生亮屏进入锁屏界面（插件不干预） |
| 常亮显示（AOD）处于显示态 + 手电筒开启，按侧键 | 手电筒保持开启，与未安装插件一致 |
| 无闪光灯设备（iPad、iPod touch） | 侧键行为完全不变，零干预、零日志 |
| 屏幕已熄灭 + 手电筒开启时双击侧键 | 相机按原生行为打开；第一次按压关灯且不亮屏，不妨碍第二次按压被识别为双击 |
| 长按侧键（SOS 紧急联络）、长按 + 音量键（强制重启） | 原生行为，插件不拦截、不干扰 |

### 判定与执行口径

- **是否开着手电筒**：读系统手电筒通道 `-[SBUIFlashlightController level] > 0`。无论灯是从锁屏快捷按钮、控制中心还是其它官方入口开启的，判定都与该入口一致。
- **关灯动作**：同样走系统自己的通道 `-[SBUIFlashlightController turnFlashlightOffForReason:]`，因此锁屏按钮、控制中心、灵动岛 / 状态栏的手电筒状态始终同步，不会出现「灯已灭但界面仍显示开启」或反之。

## 兼容性与验证状态

插件依赖的私有符号已逐个在 iOS 17.1 (21B80) 的 dyld shared cache 中确认存在；roothide 包已在 iOS 16.1.2 与 iOS 17.1 真机上完成功能验证。

| 包 | 适用环境 | deb 内 dylib 路径 | Architecture | 二进制 slice | 真机验证 |
|---|---|---|---|---|---|
| `TorchOffOnSleep_1.0.0_roothide_arm64e.deb` | roothide / bootstrap | `Library/MobileSubstrate/DynamicLibraries/` | `iphoneos-arm64e` | 仅 `arm64e` | iOS 16.1.2 与 iOS 17.1 均已通过 |
| `TorchOffOnSleep_1.0.0_rootless_arm64.deb` | rootless | `var/jb/Library/MobileSubstrate/DynamicLibraries/` | `iphoneos-arm64` | `arm64` + `arm64e` | 仅完成静态检查，未上真机 |

两个包的包 id 相同（`com.tune.torchoffonsleep`），**不要装到同一个环境**：同一环境装两个会互相覆盖，且安装根不同，装错环境不会按预期加载。请按设备实际的越狱环境二选一。

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

`killall -9 SpringBoard` 即 respring；环境里若有 `sbreload` 也可代替。

## 卸载

在设备上以 root 执行：

```bash
dpkg -r com.tune.torchoffonsleep
killall -9 SpringBoard
```

卸载即完全恢复原生行为：插件不写持久化状态、不写配置文件、不注册守护进程，dylib 随包删除后无残留。

若 SpringBoard 因此无法启动，进安全模式，或经 SSH 删除 dylib 后 respring：

```bash
# roothide / bootstrap
rm -f /Library/MobileSubstrate/DynamicLibraries/TorchOffOnSleep.dylib
killall -9 SpringBoard
```

```bash
# rootless
rm -f /var/jb/Library/MobileSubstrate/DynamicLibraries/TorchOffOnSleep.dylib
killall -9 SpringBoard
```

## 从源码构建

正式打包入口只有 `scripts/build_packages.sh`：它依次构建 roothide 与 rootless 两个包，核对产物名与包头，净化宿主元数据，并把 deb 收敛输出到 `out/`。在仓库根目录执行：

```bash
THEOS=/opt/theos ./scripts/build_packages.sh
```

前置条件：theos 位于 `/opt/theos`（含 `vendor/mod/roothide` 与 `vendor/mod/rootless`），系统有 `make`、`dpkg-deb`、`find`、`sed`、`mktemp`、`cp`、`kill`、`sleep`。脚本启动时会自检，缺一项即报错退出。

可用环境变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `THEOS` | `/opt/theos` | theos 根目录 |
| `ENABLE_ROOTFUL` | 不设置 | 置 `1` 时额外构建 rootful 包（`THEOS_PACKAGE_SCHEME` 显式为空），默认不构建 |
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

三个开关都用 `#ifndef` 包裹，可在 `make` 命令行用 `TorchOffOnSleep_CFLAGS` 覆盖，无需改源码：

| 开关 | 默认 | 作用 |
|---|---|---|
| `TORCH_OFF_SUPPRESS_WAKE` | `1` | `1` = 关灯后不调 `%orig`，屏幕保持熄灭；`0` = 关灯并亮屏。影响主 hook 与第一个备选 hook 点 |
| `TORCH_OFF_ENABLE_LOG` | `0` | `0` = 零日志；`1` = 用 `os_log` 打印拦截命中、关灯调用与当前生效的 hook 层（排障用） |
| `TORCH_OFF_ENABLE_FILELOG` | `1`（源码默认）／`0`（`scripts/build_packages.sh` 正式构建强制） | `0` = 关闭文件日志通道，不写任何 `.log`，二进制内也不含日志路径字符串；`1` = 调试时把日志写到 dylib 同目录 / `/tmp`，供 SSH 排障。正式包必须为 `0`，保证不写持久化状态 |

注意：make 命令行的 `TorchOffOnSleep_CFLAGS` 会整体覆盖 Makefile 里的取值，重新指定时必须把 `-fobjc-arc` 一起带上。示例（构建「关灯并亮屏」行为的 rootless 包）：

```bash
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless TorchOffOnSleep_CFLAGS="-fobjc-arc -DTORCH_OFF_SUPPRESS_WAKE=0"
```

调试时如需文件日志，可临时手动 `make` 并显式传 `-DTORCH_OFF_ENABLE_FILELOG=1`。

### 构建后自检

```bash
dpkg-deb -f out/TorchOffOnSleep_1.0.0_roothide_arm64e.deb Package Version Architecture
dpkg-deb -f out/TorchOffOnSleep_1.0.0_rootless_arm64.deb Package Version Architecture
rm -rf /tmp/torchoff-rootless && dpkg-deb -R out/TorchOffOnSleep_1.0.0_rootless_arm64.deb /tmp/torchoff-rootless
lipo -archs /tmp/torchoff-rootless/var/jb/Library/MobileSubstrate/DynamicLibraries/TorchOffOnSleep.dylib
find /tmp/torchoff-rootless \( -name .DS_Store -o -name '._*' -o -name __MACOSX \) -print
```

判据：roothide 包为 `Architecture: iphoneos-arm64e`，rootless 包为 `iphoneos-arm64`；rootless 包的 dylib 应同时含 `arm64` 与 `arm64e` 两个 slice；最后一条 `find` 的输出应为空。

## 工作原理

### hook 点

插件只 hook 唤醒路径上的一个方法：

- `-[SBSleepWakeHardwareButtonInteraction _performWake]`

同时对它的子类 `SBDoubleClickSleepWakeHardwareButtonInteraction` 也装一份。反编译确认子类覆盖了 `_performWake`，而 Substrate 的 hook 替换的是具体类的 IMP——只 hook 父类时，设备实例化子类会让父类被 hook 的 IMP 被绕过，插件静默失效。

命中判据是：`SBUIFlashlightController` 存在、`sharedInstance` 存在、`level > 0`；若当前系统存在 `+deviceSupportsFlashlight`，还会要求它为真（iPad / iPod touch 零干预）。iOS 16.1.2 实测该 selector 不存在，此时跳过该检查。未命中时直接 `%orig`，走原生逻辑。

### 为什么屏幕状态不用自己判断

`_performWake` 位于系统全部前置判定之后：`consumeInitialPressDown` 已判过 `screenIsDim`（AOD 开启时还判了 `backlightState != 3`），`_performWake` 开头又判了 `shouldNeverLock`、`!screenIsDim`、`caseIsEnabledAndLatched`。

能执行到 `_performWake`，就等于「系统已经决定要亮屏」。因此插件不实现任何屏幕状态判断，直接复用系统在该按压时刻的既有判定结果——重复判断只会与系统语义（尤其是 AOD 相关分支）产生漂移。

### 其它实现要点

- **补 `setInhibitNextSinglePressUp:YES`**：原生 `_performWake` 在亮屏成功后会把该标志置 YES，使松手阶段的 `consumeSinglePressUp` 变成空操作。插件关灯后不调 `%orig`，这个赋值就不会发生，松手时会误走 `_performSleep()`（表现为多一声锁屏音加一次锁屏动画），所以显式复用它。
- **关灯走系统通道**：`-[SBUIFlashlightController turnFlashlightOffForReason:]`，保证各官方入口的手电筒状态一致。
- **注入过滤**：`TorchOffOnSleep.plist` 只注入 `com.apple.springboard`，不碰其它进程。
- **按符号可用性择一装填**：依次尝试 `_performWake` → `consumeInitialPressDown` → `performSinglePressAction` 三个 hook 点，取第一个可用的装填；三个都不可用则什么都不装，侧键行为与原生一致。装填在 tweak 构造函数（`%ctor`）里**同步**完成：注入进已运行的 SpringBoard 时目标类必然已注册，当场即可装填，不依赖主队列；只有构造期一个类都没响应时，才回退到主队列再试一次。降级判断不在按压路径上临时探测。
- **无运行时配置**：没有设置界面、没有配置文件、没有守护进程，只有三个编译期开关。

## 已知限制

1. **其它 iOS 17.x 小版本未逐一验证。** roothide 包已在 iOS 17.1 与 iOS 16.1.2 真机上通过；17.0、17.2–17.4 等其它小版本未逐台测试，符号可用性由备选 hook 点与 `respondsToSelector:` 判空兜底。
2. **淡出到锁屏的约 0.3 s 窗口内连按两次**：原生会逆转淡出、让屏幕回来；本插件会改为关灯并保持淡出。v1 不处理这个差异。
3. **最后一个备选 hook 点无法抑制亮屏**：当 `_performWake` 与 `consumeInitialPressDown` 都不可用时，插件退到 hook `-[SBLockHardwareButtonActions performSinglePressAction]`。该点位于松手阶段，亮屏早已发生，语义只能退化为「亮屏 + 关灯」，`TORCH_OFF_SUPPRESS_WAKE` 在这一层无效。该层额外带一个屏幕守卫：借 `+[SBBacklightController sharedInstanceIfExists]` 取实例并读 `screenIsDim`，只在屏幕**未完全点亮**（熄灭或变暗）时才关灯；守卫拿不到实例、或 `screenIsDim` 不可用时选择**不干预**（少关一次灯可以接受，在屏幕点亮时关手电筒才是要避免的）。
4. **AOD 显示态不关灯**：常亮显示处于显示态时，系统本身不执行亮屏动作，插件继承该语义，同样不关灯。
5. **rootless 包只验到包结构与 slice**：未验证 rootless 环境下 SpringBoard 是否真的加载它。
6. **`homeButtonType == 2` 对应哪种设备形态未确认**：已用「父类与子类都 hook」规避，但若某版本引入第三种实现，仍会漏。

## 仓库结构

```
Makefile                          theos 构建定义（ARCHS 按 scheme 分流）
control                           deb 元数据（Package: com.tune.torchoffonsleep）
TorchOffOnSleep.plist             注入过滤（仅 com.apple.springboard）
Tweak.xm                          全部插件逻辑（单文件）
scripts/build_packages.sh         统一打包入口（两个包 + 符号门禁）
scripts/verify_symbols.sh         固件符号契约门禁（20 个符号）
out/                              构建产物（两个 deb）
```
