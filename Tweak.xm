// TorchOffOnSleep：段 ① 配置区（Design Doc §2 的 ① 段 + §5 的日志宏）。
// 设计文档代码块不含 import，但 NSObject / NSString 等基类型必须来自
// Foundation；UIKit 自 Foundation 派生，缺导入会报
// "cannot find interface declaration for 'NSObject'"，故在文件开头导入。
#import <UIKit/UIKit.h>

#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>

/* 三个编译期开关：均可用 make 命令行的 TorchOffOnSleep_CFLAGS 覆盖，
   因此必须用 #ifndef 包裹，不能把值写死。
   - SUPPRESS_WAKE 默认 1（方案 A：不调 %orig，屏幕保持熄灭）
   - ENABLE_LOG 默认 0（零 os_log，不给 SpringBoard 日常使用增加日志噪音）
   - ENABLE_FILELOG 默认 1（文件日志通道，真机排障用；正式发布版必须置 0，
     见下方说明——它不依赖 os_log/Console，SSH 里 find + cat 即可读取） */
#ifndef TORCH_OFF_SUPPRESS_WAKE
    #define TORCH_OFF_SUPPRESS_WAKE 1
#endif

#ifndef TORCH_OFF_ENABLE_LOG
    #define TORCH_OFF_ENABLE_LOG 0
#endif

#ifndef TORCH_OFF_ENABLE_FILELOG
    #define TORCH_OFF_ENABLE_FILELOG 1
#endif

/* 关灯原因字符串：内容自定义，SpringBoardUI 只把它当去重/日志用的 tag。 */
static NSString *const kTorchOffReason = @"TorchOffOnSleep";

/* 日志宏的两种形态（照抄 Design Doc §5）：默认关闭 ⇒ 编译期变成空语句。 */
#if TORCH_OFF_ENABLE_LOG
    #include <os/log.h>
    #define TOOLLog(fmt, ...) os_log(OS_LOG_DEFAULT, "[TorchOffOnSleep] " fmt, ##__VA_ARGS__)
#else
    #define TOOLLog(fmt, ...) do { } while (0)
#endif

/* 文件日志通道。引入原因：真机测试出现"零日志、零效果"，而原实现把整个初始化
   押在 %ctor 里一次 dispatch_async 上（反编译确认构造函数除了 dispatch_async
   什么都不做）。一旦那次投递没成功，就没有 %init、没有日志、没有任何效果，
   现象与现场完全一致。因此需要一条**不依赖 os_log / Console** 的硬通道来定位。

   路径取 dylib 自身所在目录（dladdr 自省），roothide 与 rootless 两种环境都
   无需假设 jbroot；目录不可写时退到 /tmp。os_log 通道保留，两路都写。 */
static char g_toolLogPath[1152];

static void TOOLInitLogPath(void)
{
    g_toolLogPath[0] = '\0';

    Dl_info info;
    if (dladdr((void *)TOOLInitLogPath, &info) && info.dli_fname && info.dli_fname[0]) {
        snprintf(g_toolLogPath, sizeof(g_toolLogPath), "%s.log", info.dli_fname);
        /* 立刻试写一次：dylib 目录不一定可写（属主/selinux），不可写就退到 /tmp */
        FILE *probe = fopen(g_toolLogPath, "a");
        if (probe) {
            fclose(probe);
            return;
        }
    }
    snprintf(g_toolLogPath, sizeof(g_toolLogPath), "/tmp/TorchOffOnSleep.log");
}

#if TORCH_OFF_ENABLE_FILELOG
static void TOOLFileLog(const char *fmt, ...)
{
    if (!g_toolLogPath[0]) return;

    FILE *f = fopen(g_toolLogPath, "a");
    if (!f) return;

    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}
    #define TOOLBOTH(fmt, ...)                  \
        do {                                    \
            TOOLFileLog(fmt, ##__VA_ARGS__);    \
            TOOLLog(fmt, ##__VA_ARGS__);        \
        } while (0)
#else
    #define TOOLFileLog(fmt, ...) do { } while (0)
    #define TOOLBOTH(fmt, ...)  TOOLLog(fmt, ##__VA_ARGS__)
#endif

// TorchOffOnSleep：段 ② 私有接口声明（只声明用到的选择子）。
// Design Doc §2.1 的接口块不含 import，但 NSObject/NSString 等基类型必须来自
// Foundation，否则整段无法编译，故在此补一行最小导入。
#import <Foundation/Foundation.h>

@interface SBUIFlashlightController : NSObject
+ (instancetype)sharedInstance;
+ (BOOL)deviceSupportsFlashlight;
- (NSUInteger)level;
- (void)turnFlashlightOffForReason:(NSString *)reason;
@end

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstanceIfExists;  // 降级 3 专用：只取已有实例，不创建
- (BOOL)screenIsDim;          // 降级 2 与降级 3 的屏幕守卫
@end

@interface SBSleepWakeHardwareButtonInteraction : NSObject
- (void)setInhibitNextSinglePressUp:(BOOL)flag;  // 主 + 降级 2
- (BOOL)consumeInitialPressDown;                 // 降级 2
- (SBBacklightController *)backlightController;  // 降级 2
@end

/* 子类必须显式声明继承关系。Logos 对未声明 @interface 的被 hook 类只生成
   @class 前向声明，编译器因此不知道 self 拥有父类接口里的方法，
   调用 setInhibitNextSinglePressUp: 会报 "forward declaration"。
   声明空接口 + 继承后，父类接口的方法对子类可见。 */
@interface SBDoubleClickSleepWakeHardwareButtonInteraction
    : SBSleepWakeHardwareButtonInteraction
@end

@interface SBLockHardwareButtonActions : NSObject
@end

// TorchOffOnSleep：段 ③ 判据函数（Design Doc §2.2 逐字符照抄）。
// 设计约束：判据只依赖 SBUIFlashlightController 一个类，屏幕状态不在这里判
//——它由主 hook 的位置免费继承。全程判空，%c() 对不存在的类返回 nil 而非
// 崩溃，天然适合做降级判空。

static BOOL TOOLShouldIntercept(void)
{
    Class cls = %c(SBUIFlashlightController);
    if (!cls)                                          return NO;
    if (![cls respondsToSelector:@selector(deviceSupportsFlashlight)]) return NO;
    if (![cls deviceSupportsFlashlight])               return NO;   // iPad / iPod touch
    if (![cls respondsToSelector:@selector(sharedInstance)])         return NO;

    SBUIFlashlightController *fc = [cls sharedInstance];
    if (!fc)      { TOOLBOTH("predicate: no sharedInstance");      return NO; }
    if (![fc respondsToSelector:@selector(level)]) {
        TOOLBOTH("predicate: no level selector");                 return NO;
    }

    NSUInteger lv = [fc level];
    TOOLBOTH("predicate: level=%lu", (unsigned long)lv);
    return lv > 0;
}

// TorchOffOnSleep：段 ③.5 关灯入口与屏幕状态取用（三个 hook 层共用的基础设施）。
//
// 两块内容都从各层方法体里抽出来放到这里，理由是三处降级必须共用同一份实现：
//   - TOOLTurnOffTorch()：全项目唯一的关灯调用点，带 @try/@catch 异常守卫（I3）
//     与关灯日志（I4）。"先关灯、成功才置 inhibit"的顺序也只有这一份。
//   - 屏幕状态取用：降级 2 的 self 是 interaction 实例，有 backlightController
//     方法；降级 3 的 self 是 SBLockHardwareButtonActions，没有该方法，只能改从
//     类方法取实例。两条入口都遵守同一条铁律：拿不到信息就不做抑制决定。

/* 唯一的关灯调用点。返回 YES = 关灯调用正常返回；NO = 控制器拿不到 / 选择子缺失 /
   调用抛异常。调用方拿到 NO 时必须走完整原生路径：不置
   setInhibitNextSinglePressUp:、不抑制亮屏，本次按压与未装插件时完全一致。 */
static BOOL TOOLTurnOffTorch(void)
{
    SBUIFlashlightController *fc = [%c(SBUIFlashlightController) sharedInstance];
    if (!fc)                                                        return NO;
    if (![fc respondsToSelector:@selector(turnFlashlightOffForReason:)]) return NO;

#if TORCH_OFF_ENABLE_LOG
    /* I4：把关灯前的 level 一起打出来，日志才能回答"灯当时到底亮没亮"。
       必须用 #if 包住：TORCH_OFF_ENABLE_LOG=0 时 TOOLLog 展开为空语句，这个
       变量会被判未使用，而 theos 带 -Werror，会直接编译失败。 */
    NSUInteger levelBefore = [fc respondsToSelector:@selector(level)] ? [fc level] : 0;
#endif

    /* I3：turnFlashlightOffForReason: 内部是 setLevel:0 → _setFlashlightLevel:
       → AVFoundation，任何一层抛 ObjC 异常都会穿过我们的 hook 直达 SpringBoard
       的 HID 路径，最坏结果是 SpringBoard 崩溃、设备不可用。delta spec 明确要求
       "本次按压 MUST NOT 导致 SpringBoard 崩溃"，所以这里必须接住。 */
    @try {
        [fc turnFlashlightOffForReason:kTorchOffReason];
#if TORCH_OFF_ENABLE_FILELOG
        TOOLFileLog("torch off called (level before=%lu)",
                    (unsigned long)([fc respondsToSelector:@selector(level)] ? [fc level] : 0));
#endif
    } @catch (NSException *e) {
        TOOLLog("turnFlashlightOffForReason: 抛出异常：%{public}@", e.reason);
        return NO;
    }

    /* I4：文档承诺的"关灯调用"日志，只有真正调成功才打。 */
    TOOLLog("手电筒已关闭（调用前 level=%lu）", (unsigned long)levelBefore);
    return YES;
}

/* 从类方法取 SBBacklightController 实例（降级 3 唯一可用的入口）。
   用 sharedInstanceIfExists 而不是 sharedInstance：后者在实例不存在时会创建它，
   而我们在松手阶段只是"问一句屏幕亮不亮"，没有理由产生创建背光控制器的副作用。
   三级判空：类不存在 → 类不响应该选择子 → 实例为 nil。任一级失败返回 nil，
   调用方按"拿不到屏幕状态 ⇒ 不干预"处理。 */
static SBBacklightController *TOOLBacklightController(void)
{
    Class cls = %c(SBBacklightController);
    if (!cls)                                                    return nil;
    if (![cls respondsToSelector:@selector(sharedInstanceIfExists)]) return nil;
    return [cls sharedInstanceIfExists];
}

/* 降级 2 的屏幕守卫（Design Doc §3.2，三级判空照抄）：从 interaction 实例取。
   respondsToSelector(backlightController) → 非 nil → respondsToSelector(screenIsDim)。
   任一级拿不到就返回 NO（= "不敢说屏幕没全亮"），让调用方走 %orig，
   绝不在信息不足时做抑制决定。 */
static BOOL TOOLScreenIsNotFullyOn(id interaction)
{
    if (![interaction respondsToSelector:@selector(backlightController)]) return NO;
    id bl = [interaction backlightController];
    if (!bl) return NO;
    if (![bl respondsToSelector:@selector(screenIsDim)]) return NO;
    return [bl screenIsDim];
}

/* 降级 3 的屏幕守卫（I2）：self 是 SBLockHardwareButtonActions，没有
   backlightController 方法，所以必须走上面的类方法入口，不能复用基于 self 的
   TOOLScreenIsNotFullyOn()——那样会恒返回 NO，把降级 3 变成纯透传。
   拿不到实例或 screenIsDim 不可用都返回 NO，方向选"不干预"：这一个按压少关一次
   灯可以接受，在屏幕还亮着时关灯则违反 delta spec 的
   「MUST NOT 在屏幕点亮状态下关闭手电筒」。 */
static BOOL TOOLScreenIsNotFullyOnViaBacklightController(void)
{
    SBBacklightController *bl = TOOLBacklightController();
    if (!bl) return NO;
    if (![bl respondsToSelector:@selector(screenIsDim)]) return NO;
    return [bl screenIsDim];
}

// TorchOffOnSleep：段 ④ hooks —— 本任务只做主 group（第 1 层）的两个类。
// 降级 2 / 降级 3 的 group 由后续任务追加，此处不写。
//
// 两个类各用一个独立 group，不用"同一 group 内连续两个 %hook"的紧凑写法——
// 该写法依 Logos 版本而异，拆开无歧义。两个 group 的方法体一致（仅日志里标注了
// 子类），实际逻辑靠调用同一个共享函数保证：改一处即改两处，不会漏。
//
// 覆盖两个类的原因（Design Doc §3.0）：Substrate 的 hook 替换的是具体类的 IMP。
// SBDoubleClickSleepWakeHardwareButtonInteraction 覆盖了 _performWake，若只 hook
// 父类，设备实例化子类时父类被 hook 的 IMP 会被绕过 ⇒ 插件静默失效。
//
// 为什么 hook 内不含任何屏幕状态判断（D2）：_performWake 位于系统全部前置判定
// 之后——consumeInitialPressDown 已判过 screenIsDim（AOD 开启时还判了
// backlightState != 3），_performWake 开头又判了 shouldNeverLock / !screenIsDim /
// caseIsEnabledAndLatched。能执行到这里，就等于"系统已经决定要亮屏"，delta spec
// 的「屏幕已熄灭」条件由构造保证；在此重复判断只会引入漂移。
//
// 为什么 setInhibitNextSinglePressUp:YES 必须补（D4）：原生 _performWake 在亮屏
// 成功后会把该标志置 YES，使松手阶段的 consumeSinglePressUp 变成空操作。方案 A
// 不调 %orig，这个赋值就不会发生，松手时会走 _performSleep()——表现为多一声锁屏音
// + 一次锁屏动画。复用它而不是自造标志位。

/* 共享实现：关手电筒 → 成功才抑制下一次松手 → 视 TORCH_OFF_SUPPRESS_WAKE 决定是否
   调原生。判据判定放在 hook 里：未命中直接 %orig 返回，不进这里。
   顺序很关键（I3）：关灯必须先于置 inhibit。关灯失败时完整走原生路径，绝不留
   "松手被抑制但灯没关"的半拦截状态。
   "是否调原生"做成 block 传进来：%orig 只能写在 %hook 块内、不能传参，所以每个
   group 各留一个极薄的转发方法，把真正的 %orig 调用留在 hook 块里。 */
static void TOOLTurnOffTorchAndMaybeSuppress(id self, void (^callOrig)(void))
{
    if (!TOOLTurnOffTorch()) { callOrig(); return; }   // 关灯失败 ⇒ 完全走原生

    if ([self respondsToSelector:@selector(setInhibitNextSinglePressUp:)])
        [self setInhibitNextSinglePressUp:YES];

#if TORCH_OFF_SUPPRESS_WAKE
    return;      // 不调用 %orig ⇒ 屏幕保持熄灭
#else
    callOrig();  // 原生亮屏照常发生
#endif
}

%group TorchOffPerformWake
%hook SBSleepWakeHardwareButtonInteraction
- (void)_performWake
{
    if (!TOOLShouldIntercept()) { %orig; return; }
    TOOLLog("命中拦截判据：第 1 层主 hook _performWake");
    TOOLTurnOffTorchAndMaybeSuppress(self, ^{ %orig; });
}
%end
%end

%group TorchOffPerformWakeDoubleClick
%hook SBDoubleClickSleepWakeHardwareButtonInteraction
- (void)_performWake
{
    if (!TOOLShouldIntercept()) { %orig; return; }
    TOOLLog("命中拦截判据：第 1 层主 hook _performWake（子类）");
    TOOLTurnOffTorchAndMaybeSuppress(self, ^{ %orig; });
}
%end
%end

// TorchOffOnSleep：段 ⑤ 降级 2 —— consumeInitialPressDown（Design Doc §3.2）。
// 与主 group 一样对两个类各写一个独立 group（原因见段 ④ 注释与 Design Doc
// §3.0）：SBDoubleClickSleepWakeHardwareButtonInteraction 覆盖了
// consumeInitialPressDown，只 hook 父类会在设备实例化子类时静默漏掉。
//
// 为什么这一层要多判一个 TOOLScreenIsNotFullyOn()（定义见段 ③.5，与降级 3 的
// 屏幕守卫放在一起）：consumeInitialPressDown 位于
// _performWake 之前，系统自己的屏幕判定还没替我们做完——主 group 的「屏幕已熄灭」
// 是由所处位置免费继承的（见段 ④ 注释 D2），降级 2 继承不到。不补这一判，就会在
// 手电筒开着、屏幕其实还亮着时把按下消费掉，用户连点亮屏幕都做不到。
//
// 这一层不处理 AOD 分支（backlightState != 3）：降级路径宁可少覆盖，也不冒误拦截
// 的风险；真实设备走的是主 group。
//
// 为什么不复用主 group 的 TOOLTurnOffTorchAndMaybeSuppress：那个返回 void、语义是
// "抑制亮屏与否"；这里要返回 BOOL（是否消费本次按下），签名与返回值都不同，故另写
// 一个，避免把两种返回值搅在一个函数里。

/* 共享实现（Design Doc §3.2 的 TOOLConsumeInitialPressDownBody）：判据 + 屏幕未全亮
   ⇒ 关手电筒 → 成功才抑制下一次松手 → 视 TORCH_OFF_SUPPRESS_WAKE 决定是消费掉本次
   按下还是放行。未命中直接 %orig。
   顺序同样关键（I3）：先关灯，失败则原样返回原生结果——不置 inhibit、不消费按下，
   本次按压与未装插件时一致。
   %orig 只能写在 %hook 块内，故沿用段 ④ 的 block 转发手法；这里的 block 返回 BOOL，
   好让"未命中"分支原样带回原生的返回值。 */
static BOOL TOOLConsumeInitialPressDownBody(id self, BOOL (^callOrig)(void))
{
    if (TOOLShouldIntercept() && TOOLScreenIsNotFullyOn(self)) {
        TOOLLog("命中拦截判据且屏幕未全亮：第 2 层降级 consumeInitialPressDown");

        if (!TOOLTurnOffTorch()) return callOrig();   // 关灯失败 ⇒ 完全走原生

        if ([self respondsToSelector:@selector(setInhibitNextSinglePressUp:)])
            [self setInhibitNextSinglePressUp:YES];

#if TORCH_OFF_SUPPRESS_WAKE
        return YES;   // 消费掉本次按下，不亮屏
#else
        callOrig();   // 原生亮屏照常发生
        return YES;
#endif
    }
    return callOrig();
}

// 两个 group 方法体逐字符相同（靠调同一个共享函数保证：改一处即改两处，不会漏）。
// 改方法体时无需同步改两处；若改共享函数，则两个 group 同时生效——这正是抽取它的目的。

%group TorchOffConsumeInitialPressDown
%hook SBSleepWakeHardwareButtonInteraction
- (BOOL)consumeInitialPressDown
{
    return TOOLConsumeInitialPressDownBody(self, ^{ return %orig; });
}
%end
%end

%group TorchOffConsumeInitialPressDownDoubleClick
%hook SBDoubleClickSleepWakeHardwareButtonInteraction
- (BOOL)consumeInitialPressDown
{
    return TOOLConsumeInitialPressDownBody(self, ^{ return %orig; });
}
%end
%end

// TorchOffOnSleep：段 ⑥ 降级 3 —— SBLockHardwareButtonActions
// -performSinglePressAction（Design Doc §3.3）。
// 这是最后一层：hook 的是 actions 对象而不是 interaction，且位于松手阶段，而原生
// 亮屏发生在按下瞬间，所以它只能做到"亮屏 + 关灯"，无法实现方案 A 的抑制亮屏，
// TORCH_OFF_SUPPRESS_WAKE 在这一层无效。
// 因此 %orig 无条件出现在判据之外、不被任何 #if 包裹：亮屏早已发生，拦不住也不必拦。
//
// 与 Design Doc §3.3 代码块的唯一差异（I2）：判据里多了一个屏幕守卫。
// §3.3 只判手电筒不判屏幕，而 performSinglePressAction 在"屏幕点亮时按侧键息屏"
// 这条路径上同样被调用，那一按会被插件关掉手电筒，违反 delta spec 的
// 「MUST NOT 在屏幕点亮状态下关闭手电筒」。守卫只能从类方法取 SBBacklightController
// （本层的 self 是 SBLockHardwareButtonActions，没有 backlightController 方法），
// 取不到就不干预——降级路径宁可少覆盖一次，也不冒误关灯的风险。

%group TorchOffSinglePress
%hook SBLockHardwareButtonActions

- (void)performSinglePressAction
{
    if (TOOLShouldIntercept() && TOOLScreenIsNotFullyOnViaBacklightController()) {
        TOOLLog("命中拦截判据且屏幕未全亮：第 3 层降级 performSinglePressAction");
        /* I3：本层本来就无条件 %orig，关灯失败只是少关一次灯，不存在"抑制亮屏 /
           置 inhibit"的半拦截状态；仍走同一入口以复用异常守卫。 */
        TOOLTurnOffTorch();
    }
    %orig;   // 必须调：亮屏早在按下瞬间已发生，这里拦不住
}

%end
%end

// TorchOffOnSleep：段 ⑦ 降级装填与构造函数（Design Doc §3.4 / §4）。
//
// Logos 硬约束（承接原过渡态注释的结论）：文件里出现多个具名 %group 时，Logos 拒绝
// 自动生成构造函数（"Cannot generate an autoconstructor with multiple %groups.
// Please explicitly create a constructor."），而每个 initRequired 的 group 又必须被
// %init 过一次，否则预处理即报 "non-initialized hook groups: ..."。因此具名 group
// 一旦落盘，就必须同时有且只有一个显式 %ctor，且它必须覆盖全部 5 个 group 的装填
// 决策——本段就是这个唯一的 %ctor，不要再写第二个，也不要再出现裸 %init()。

/* Design Doc §5 只定义了 TOOLLog，而 §4 的 TOOLInstallHooks() 用到了
   TOOLLogInstalled(<层号>)，这里按同一风格补齐。定义成宏而不是函数，是为了让 §4 的
   函数体保持逐字符照抄。
   关日志的分支不能省：否则 TORCH_OFF_ENABLE_LOG=0（默认）下 TOOLLogInstalled(1)
   就是一次未声明函数调用，而 theos 带 -Werror，会直接编译失败。 */
#if TORCH_OFF_ENABLE_LOG
    #define TOOLLogInstalled(layer) TOOLLog("hooks installed at layer %d", (int)(layer))
#else
    #define TOOLLogInstalled(layer) do { } while (0)
#endif

/* TOOLClassResponds（Design Doc §4）：%c() 对不存在的类返回 nil 而非崩溃，所以先
   判空、再问 instancesRespondToSelector:，把"类不存在"和"类不响应该选择子"折叠成
   同一个 NO。调用方因此不必各自判空，也绝不会在 nil 上发消息。 */
static inline BOOL TOOLClassResponds(Class cls, SEL sel)
{
    return cls && [cls instancesRespondToSelector:sel];
}

/* TOOLInstallHooks（Design Doc §4，第 2 层条件按 I1 加固，其余逐字符照抄）：
   三层互斥降级装填。
   互斥只发生在层与层之间——装上前两层任意一组即记录层号并 return，不再往下看；
   第 1、2 层内部对父类与子类是并行覆盖关系，两个 if 之间既无 else 也无 return，
   两个都装（原因见段 ④ 注释与 Design Doc §3.0：子类覆盖了同名方法，只 hook 父类
   会在设备实例化子类时静默漏掉）。
   三层全不满足 ⇒ 什么都不装，只记层号 0（静默失效，不留半吊子 hook）。 */
static BOOL TOOLInstallHooks(void)
{
    BOOL installedWake = NO;

    /* 第 1 层：_performWake —— 对父类与子类都装（见 §3.0） */
    if (TOOLClassResponds(%c(SBSleepWakeHardwareButtonInteraction),
                          @selector(_performWake))) {
        %init(TorchOffPerformWake);
        installedWake = YES;
    }
    if (TOOLClassResponds(%c(SBDoubleClickSleepWakeHardwareButtonInteraction),
                          @selector(_performWake))) {
        %init(TorchOffPerformWakeDoubleClick);
        installedWake = YES;
    }
    if (installedWake) { TOOLBOTH("installed at layer 1"); return YES; }

    /* 第 2 层：consumeInitialPressDown —— 同样覆盖两个类。
       置 YES 的前提从"consumeInitialPressDown 存在"加固为"consumeInitialPressDown
       与 backlightController 都存在"（I1，父类与子类各自判断）：本层的屏幕判定链
       第一环就是 [interaction backlightController]，缺它则 TOOLScreenIsNotFullyOn()
       第一级就返回 NO ⇒ 这一层退化成纯 %orig 透传，却仍把 installedDown 置 YES，
       第 3 层永不被装填 ⇒ 插件整体静默失效，而符号门禁可能一路全绿。
       两个符号都问过再装，缺失时继续往下落到第 3 层。 */
    BOOL installedDown = NO;
    if (TOOLClassResponds(%c(SBSleepWakeHardwareButtonInteraction),
                          @selector(consumeInitialPressDown))
        && TOOLClassResponds(%c(SBSleepWakeHardwareButtonInteraction),
                             @selector(backlightController))) {
        %init(TorchOffConsumeInitialPressDown);
        installedDown = YES;
    }
    if (TOOLClassResponds(%c(SBDoubleClickSleepWakeHardwareButtonInteraction),
                          @selector(consumeInitialPressDown))
        && TOOLClassResponds(%c(SBDoubleClickSleepWakeHardwareButtonInteraction),
                             @selector(backlightController))) {
        %init(TorchOffConsumeInitialPressDownDoubleClick);
        installedDown = YES;
    }
    if (installedDown) { TOOLBOTH("installed at layer 2"); return YES; }

    /* 第 3 层：performSinglePressAction */
    if (TOOLClassResponds(%c(SBLockHardwareButtonActions),
                          @selector(performSinglePressAction))) {
        %init(TorchOffSinglePress);
        TOOLBOTH("installed at layer 3");
        return YES;
    }

    TOOLBOTH("installed at layer 0 (no class responded)");   // 三层全无 ⇒ 静默失效
    return NO;
}

/* 唯一的构造函数。

   【2026-09-22 修正 — 真机"零日志、零效果"的直接原因】

   原实现把整个初始化押在一次 dispatch_async 上。反编译确认过生成的构造函数只有
   5 条指令：取 __dispatch_main_q、取全局 block、尾调用 _dispatch_async——除此之
   外什么都不做。也就是说，只要那次投递没能真正执行（构造期 libdispatch 尚未就绪、
   或加载器在非常规线程/时机注入），就没有 %init、没有日志、没有任何效果，而现场
   现象正是"零日志、零效果"。

   改为：**先在构造函数里当场装填**，只有当场一个类都没响应时才回退到主队列重试。
   这样：
   - 注入进已运行的 SpringBoard（TweakInject 的做法）时，类必然已注册 ⇒ 立即装填成功，
     完全不再依赖 dispatch_async；
   - 真遇到 dyld 构造期类未注册，回退分支仍然覆盖。
   两条路都写文件日志，一次就能分清是"没加载/ctor 没跑"还是"装填失败"。

   文件日志在构造函数最前面写，它是"ctor 到底有没有被执行"的唯一硬证据。 */
%ctor
{
    TOOLInitLogPath();
    TOOLBOTH("=== ctor ran (pid %d) ===", (int)getpid());

    if (TOOLInstallHooks()) {
        TOOLBOTH("install succeeded inside ctor");
        return;
    }

    TOOLBOTH("immediate install found nothing; deferring to main queue");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (TOOLInstallHooks())
            TOOLBOTH("install succeeded on main queue");
        else
            TOOLBOTH("install failed on main queue too");
    });
}
