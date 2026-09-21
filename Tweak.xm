// TorchOffOnSleep：段 ① 配置区（Design Doc §2 的 ① 段 + §5 的日志宏）。
// 设计文档代码块不含 import，但 NSObject / NSString 等基类型必须来自
// Foundation；UIKit 自 Foundation 派生，缺导入会报
// "cannot find interface declaration for 'NSObject'"，故在文件开头导入。
#import <UIKit/UIKit.h>

/* 两个编译期开关：默认值见 Design Doc §5。均可用 make 命令行的
   TorchOffOnSleep_CFLAGS 覆盖，因此必须用 #ifndef 包裹，不能把值写死。
   SUPPRESS_WAKE 默认 1（方案 A：不调 %orig，屏幕保持熄灭）；ENABLE_LOG
   默认 0（零日志，不给 SpringBoard 日常使用增加日志噪音）。 */
#ifndef TORCH_OFF_SUPPRESS_WAKE
    #define TORCH_OFF_SUPPRESS_WAKE 1
#endif

#ifndef TORCH_OFF_ENABLE_LOG
    #define TORCH_OFF_ENABLE_LOG 0
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
- (BOOL)screenIsDim;          // 仅降级 2 使用
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
    if (!fc)                                           return NO;
    if (![fc respondsToSelector:@selector(level)])     return NO;

    return [fc level] > 0;
}

// TorchOffOnSleep：段 ④ hooks —— 本任务只做主 group（第 1 层）的两个类。
// 降级 2 / 降级 3 的 group 由后续任务追加，此处不写。
//
// 两个类各用一个独立 group，不用"同一 group 内连续两个 %hook"的紧凑写法——
// 该写法依 Logos 版本而异，拆开无歧义。两个 group 的方法体逐字符相同（除 %hook
// 的类名），靠调用同一个共享函数保证：改一处即改两处，不会漏。
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

/* 共享实现：抑制下一次松手 → 关手电筒 → 视 TORCH_OFF_SUPPRESS_WAKE 决定是否调原生。
   判据判定放在 hook 里：未命中直接 %orig 返回，不进这里。
   "是否调原生"做成 block 传进来：%orig 只能写在 %hook 块内、不能传参，所以每个
   group 各留一个极薄的转发方法，把真正的 %orig 调用留在 hook 块里。 */
static void TOOLTurnOffTorchAndMaybeSuppress(id self, void (^callOrig)(void))
{
    if ([self respondsToSelector:@selector(setInhibitNextSinglePressUp:)])
        [self setInhibitNextSinglePressUp:YES];

    [[%c(SBUIFlashlightController) sharedInstance]
        turnFlashlightOffForReason:kTorchOffReason];

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
    TOOLTurnOffTorchAndMaybeSuppress(self, ^{ %orig; });
}
%end
%end

%group TorchOffPerformWakeDoubleClick
%hook SBDoubleClickSleepWakeHardwareButtonInteraction
- (void)_performWake
{
    if (!TOOLShouldIntercept()) { %orig; return; }
    TOOLTurnOffTorchAndMaybeSuppress(self, ^{ %orig; });
}
%end
%end

// TorchOffOnSleep：段 ⑤ 降级 2 —— consumeInitialPressDown（Design Doc §3.2）。
// 与主 group 一样对两个类各写一个独立 group（原因见段 ④ 注释与 Design Doc
// §3.0）：SBDoubleClickSleepWakeHardwareButtonInteraction 覆盖了
// consumeInitialPressDown，只 hook 父类会在设备实例化子类时静默漏掉。
//
// 为什么这一层要多判一个 TOOLScreenIsNotFullyOn()：consumeInitialPressDown 位于
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

/* 三级判空照抄 Design Doc §3.2：respondsToSelector(backlightController) → 非 nil →
   respondsToSelector(screenIsDim)。任一级拿不到就返回 NO（= "不敢说屏幕没全亮"），
   让调用方走 %orig，绝不在信息不足时做抑制决定。 */
static BOOL TOOLScreenIsNotFullyOn(id interaction)
{
    if (![interaction respondsToSelector:@selector(backlightController)]) return NO;
    id bl = [interaction backlightController];
    if (!bl) return NO;
    if (![bl respondsToSelector:@selector(screenIsDim)]) return NO;
    return [bl screenIsDim];
}

/* 共享实现（Design Doc §3.2 的 TOOLConsumeInitialPressDownBody）：判据 + 屏幕未全亮
   ⇒ 抑制下一次松手 → 关手电筒 → 视 TORCH_OFF_SUPPRESS_WAKE 决定是消费掉本次按下还是
   放行。未命中直接 %orig。
   %orig 只能写在 %hook 块内，故沿用段 ④ 的 block 转发手法；这里的 block 返回 BOOL，
   好让"未命中"分支原样带回原生的返回值。 */
static BOOL TOOLConsumeInitialPressDownBody(id self, BOOL (^callOrig)(void))
{
    if (TOOLShouldIntercept() && TOOLScreenIsNotFullyOn(self)) {
        if ([self respondsToSelector:@selector(setInhibitNextSinglePressUp:)])
            [self setInhibitNextSinglePressUp:YES];

        [[%c(SBUIFlashlightController) sharedInstance]
            turnFlashlightOffForReason:kTorchOffReason];

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
// -performSinglePressAction（Design Doc §3.3，代码块逐字符照抄）。
// 这是最后一层：hook 的是 actions 对象而不是 interaction，且位于松手阶段，而原生
// 亮屏发生在按下瞬间，所以它只能做到"亮屏 + 关灯"，无法实现方案 A 的抑制亮屏，
// TORCH_OFF_SUPPRESS_WAKE 在这一层无效。
// 因此 %orig 无条件出现在判据之外、不被任何 #if 包裹：亮屏早已发生，拦不住也不必拦。

%group TorchOffSinglePress
%hook SBLockHardwareButtonActions

- (void)performSinglePressAction
{
    if (TOOLShouldIntercept()) {
        [[%c(SBUIFlashlightController) sharedInstance]
            turnFlashlightOffForReason:kTorchOffReason];
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

/* TOOLInstallHooks（Design Doc §4 逐字符照抄）：三层互斥降级装填。
   互斥只发生在层与层之间——装上前两层任意一组即记录层号并 return，不再往下看；
   第 1、2 层内部对父类与子类是并行覆盖关系，两个 if 之间既无 else 也无 return，
   两个都装（原因见段 ④ 注释与 Design Doc §3.0：子类覆盖了同名方法，只 hook 父类
   会在设备实例化子类时静默漏掉）。
   三层全不满足 ⇒ 什么都不装，只记层号 0（静默失效，不留半吊子 hook）。 */
static void TOOLInstallHooks(void)
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
    if (installedWake) { TOOLLogInstalled(1); return; }

    /* 第 2 层：consumeInitialPressDown —— 同样覆盖两个类 */
    BOOL installedDown = NO;
    if (TOOLClassResponds(%c(SBSleepWakeHardwareButtonInteraction),
                          @selector(consumeInitialPressDown))) {
        %init(TorchOffConsumeInitialPressDown);
        installedDown = YES;
    }
    if (TOOLClassResponds(%c(SBDoubleClickSleepWakeHardwareButtonInteraction),
                          @selector(consumeInitialPressDown))) {
        %init(TorchOffConsumeInitialPressDownDoubleClick);
        installedDown = YES;
    }
    if (installedDown) { TOOLLogInstalled(2); return; }

    /* 第 3 层：performSinglePressAction */
    if (TOOLClassResponds(%c(SBLockHardwareButtonActions),
                          @selector(performSinglePressAction))) {
        %init(TorchOffSinglePress);
        TOOLLogInstalled(3);
        return;
    }

    TOOLLogInstalled(0);   // 三层全无 ⇒ 静默失效
}

/* 唯一的构造函数。装填延迟到主队列首轮（Design Doc §4.1）：本 dylib 未声明对
   SpringBoard.framework 的链接依赖，dyld 可能先跑我们的 __mod_init_func，此时
   SBSleepWakeHardwareButtonInteraction 尚未注册，%c() 返回 nil、%init 静默失败 ⇒
   插件无声失效。主队列首轮执行必然早于任何 HID 事件被处理，仍满足 delta spec 的
   「降级判断 MUST 在首次按压之前完成」。
   代价是 %ctor 与 hook 生效之间有极小窗口，期间侧键走原生逻辑，可接受。 */
%ctor
{
    dispatch_async(dispatch_get_main_queue(), ^{ TOOLInstallHooks(); });
}
