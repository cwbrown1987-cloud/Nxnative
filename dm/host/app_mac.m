// macOS App 形态（双击起）：宿主被包成 <名>.app 时，启动最前面替玩家把命令行那套准备好——
//   窗口开着（DM_WINDOW=1）；存档放 ~/Library/Application Support/<APP_NAME>/save（与开发用的工作区、测试存档都不相干）；
//   程序文件（改写后的游戏程序）随包放在 Contents/Resources/product；着色器库和着色器映射表在 Contents/Resources/msl 和
//   Contents/Resources/shader_map.tsv；游戏文件在 Contents/Resources/romfs，没有就看 Resources/paths.txt 里「romfs=本机路径」那一行
//   （链接式包：游戏文件留在本机的构建目录里，包只有几十 MB）；日志写到 ~/Library/Logs/<APP_NAME>/host.log。
// 命令行起（闸门、截图、脚本）不走这里：不在 .app 包里，或带了参数，一律原样。
// The .app form (started by double-click): the very first thing at startup prepares the command-line setup for the player --
//   the window is on; the saves go to ~/Library/Application Support/<APP_NAME>/save (unrelated to the development workspace and to the test saves);
//   the rewritten game program (the build output) is in Contents/Resources/product; the shader libraries and the shader map are in
//   Contents/Resources/msl and Contents/Resources/shader_map.tsv; the game files are in Contents/Resources/romfs, or where Resources/paths.txt
//   points (a link-style package: the game files stay in the build directory on this machine and the package stays small);
//   the log is written to ~/Library/Logs/<APP_NAME>/host.log.
// Command-line starts (gates, screenshots, scripts) do not come here: not inside an .app package, or with arguments, everything stays as it was.
#import <Cocoa/Cocoa.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include "hle.h"

static IOPMAssertionID g_sleep_id = 0;   // the assertion that keeps the display awake while the game runs
static IOReturn (*g_user_activity)(CFStringRef, IOPMUserActiveType, IOPMAssertionID *);
// Keep the display awake and undimmed: the assertion keeps it from turning off, but it may still dim, and a dimmed
// ProMotion display drops to a low refresh rate — the display link then fires every 250 ms and the picture updates
// four times a second (a flicker). Declaring user activity keeps the idle timer reset, so the display stays at its rate.
static void *keep_display_awake(void *arg) {
    (void)arg;
    for (;;) {
        usleep(20 * 1000000);
        if (g_user_activity) { IOPMAssertionID id = 0; g_user_activity(CFSTR("the game is running"), kIOPMUserActiveLocal, &id); }
    }
    return NULL;
}

#ifndef APP_NAME
#define APP_NAME "Game"   // 存档与日志目录名（建包时用 APP_NAME=... 给）| name of the save and log folder (given when the package is built: APP_NAME=...)
#endif

// 包里的一项（product / msl / romfs）：实物在 Contents/Resources/<名> 就用它；没有就看 Resources/paths.txt 里「名=本机路径」那一行
// One item of the package (product / msl / romfs): the real thing in Contents/Resources/<name> is used; otherwise the line "name=local path" in Resources/paths.txt is consulted
static NSString *res_item(NSString *name) {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *rp = NSBundle.mainBundle.resourcePath, *d = [rp stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:d]) return d;
    NSString *txt = [NSString stringWithContentsOfFile:[rp stringByAppendingPathComponent:@"paths.txt"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *ln in [txt componentsSeparatedByString:@"\n"]) { NSString *pre = [name stringByAppendingString:@"="]; if ([ln hasPrefix:pre]) { d = [ln substringFromIndex:pre.length]; return [fm fileExistsAtPath:d] ? d : nil; } }
    return nil;
}
static void alert(NSString *text) {
    NSAlert *a = [NSAlert new]; a.messageText = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @APP_NAME; a.informativeText = text; [a addButtonWithTitle:@"OK"]; [a runModal];
}

// main() 最前面调。是 App 形态就把环境与参数备好并返回 1；不是返回 0、什么都不动
// Called at the very start of main(). In the .app form it prepares the environment and the arguments and returns 1; otherwise it returns 0 and touches nothing
int dm_app_bootstrap(int *argc, char ***argv) {
    @autoreleasepool {
        NSString *bp = NSBundle.mainBundle.bundlePath;
        if (*argc > 1 || ![bp.pathExtension isEqualToString:@"app"]) return 0;
        NSFileManager *fm = NSFileManager.defaultManager;
        // 存档与日志的目录名：包的 CFBundleName（打包脚本给的名字）；没有就用编译期给的
        // The save and log folder name: the package's CFBundleName (the name the packaging script gave it); without it the one given at build time
        NSString *appName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
        if (!appName.length) appName = @APP_NAME;
        NSString *sup = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:appName] copy];
        if (getenv("DM_APP_SUPPORT")) sup = @(getenv("DM_APP_SUPPORT"));   // 测试：存档等放到指定目录，不碰玩家那份 | Test: put the saves and the rest in a given directory, leaving the player's own untouched
        NSString *logd = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:[NSString stringWithFormat:@"Logs/%@", appName]] copy];
        NSString *save = [sup stringByAppendingPathComponent:@"save"], *temp = [sup stringByAppendingPathComponent:@"temp"];
        NSString *shdump = [sup stringByAppendingPathComponent:@"shader_dump"];
        for (NSString *d in @[sup, logd, save, temp, shdump]) [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
        // 双击起没有终端：日志落文件，上几次的留几份（诊断时要对比玩家的那次和我的测试那几次）
        // A double-click start has no terminal: the log goes to a file, and the previous ones are kept
        NSString *lf = [logd stringByAppendingPathComponent:@"host.log"];
        for (int i = 3; i >= 1; i--) {   // host.1.log is the previous one, host.3.log the oldest
            NSString *from = [logd stringByAppendingPathComponent:[NSString stringWithFormat:@"host.%d.log", i - 1]];
            NSString *to = [logd stringByAppendingPathComponent:[NSString stringWithFormat:@"host.%d.log", i]];
            [fm removeItemAtPath:to error:nil];
            if ([fm fileExistsAtPath:from]) [fm moveItemAtPath:from toPath:to error:nil];
        }
        [fm removeItemAtPath:[logd stringByAppendingPathComponent:@"host.0.log"] error:nil];
        [fm moveItemAtPath:lf toPath:[logd stringByAppendingPathComponent:@"host.0.log"] error:nil];
        if (!isatty(2)) { freopen(lf.fileSystemRepresentation, "w", stderr); setvbuf(stderr, NULL, _IOLBF, 0); }
        // 不要系统的「窗口状态恢复」：上次被强退 / 崩过之后，系统会在启动时弹「上次意外退出，要重新打开窗口吗」的模态框——游戏没有可恢复的窗口，
        // 框却挡着主窗口收不到鼠标键盘（游戏在后面照跑）。等同于带启动参数 -ApplePersistenceIgnoreState YES；要在建 NSApplication 之前设
        // No system "window state restoration": after a forced quit / crash the system shows a modal "the app quit unexpectedly, reopen windows?" at launch - the game has no window to restore,
        // yet the dialog covers the main window, which then receives no mouse or keyboard (the game keeps running behind it). Equivalent to the launch argument -ApplePersistenceIgnoreState YES; must be set before NSApplication is created
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{ @"ApplePersistenceIgnoreState": @YES } forName:NSArgumentDomain];
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp activateIgnoringOtherApps:YES];
        NSString *prod = res_item(@"product"), *rom = res_item(@"romfs"), *msl = res_item(@"msl");
        NSString *shmap = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"shader_map.tsv"];   // 图形后端的着色器映射表：命令行起时按可执行文件旁的源码树找，包里放在 Resources
        if (!prod || ![fm fileExistsAtPath:[prod stringByAppendingPathComponent:@"main.patched.bin"]]) { alert(@"The package is broken: the rewritten game program (Contents/Resources/product) is missing."); exit(1); }
        if (!rom) { alert(@"The game files are missing: Contents/Resources/romfs is not there and Resources/paths.txt does not point at them."); exit(2); }
        if (!msl) { alert(@"The shader libraries are missing: Contents/Resources/msl is not there."); exit(3); }
        setenv("DM_WINDOW", "1", 1); setenv("DM_APP", "1", 1);
        setenv("DM_SAVE", save.fileSystemRepresentation, 1); setenv("DM_TEMP", temp.fileSystemRepresentation, 1);
        setenv("DM_ROMFS", rom.fileSystemRepresentation, 1); setenv("DM_ROOT", sup.fileSystemRepresentation, 1);
        if ([fm fileExistsAtPath:shmap]) setenv("DM_NVN_SHMAP", shmap.fileSystemRepresentation, 1);
        if (msl) setenv("DM_MSL_DIR", msl.fileSystemRepresentation, 1);
        if (!getenv("DM_AUDIO")) setenv("DM_AUDIO", "1", 1);   // 产品要出声 | the product must play sound
        // 屏幕不要在游戏时休眠：显示器一休眠，显示链接就停了，宿主的呈现线程在等 drawable（Metal 不再给），
        // 每帧多等 60 ms，游戏的帧率掉到一半、画面一顿一顿。等 drawable 的那段时间没法显示任何东西。
        // The display must not sleep while the game runs: once it sleeps the display link stops, the present
        // thread waits for a drawable that no longer comes (+60 ms a frame), and the game runs at half speed.
        if (!getenv("DM_NO_SLEEP")) {
            // dlopen: the power-management assertions live in IOKit, and linking it would change the shared
            // Makefile's link line (the iOS build takes its frameworks from there)
            void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
            typedef IOReturn (*mk_assert_t)(CFStringRef, IOPMAssertionLevel, CFStringRef, IOPMAssertionID *);
            typedef IOReturn (*mk_user_t)(CFStringRef, IOPMUserActiveType, IOPMAssertionID *);
            mk_assert_t mk = h ? (mk_assert_t)dlsym(h, "IOPMAssertionCreateWithName") : NULL;
            mk_user_t ku = h ? (mk_user_t)dlsym(h, "IOPMAssertionDeclareUserActivity") : NULL;
            if (mk && mk(kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelOn, CFSTR("the game is running"), &g_sleep_id) != kIOReturnSuccess)
                g_sleep_id = 0;
            // The assertion above keeps the display from turning off, but it still lets it dim, and a dimmed
            // ProMotion display drops to a low refresh rate: the display link then fires every 250 ms and the
            // picture updates four times a second (the frames stay on screen for 283 ms each - a flicker).
            // Declaring user activity keeps the idle timer reset, so the display stays at its full rate.
            g_user_activity = ku;
            if (ku) { pthread_t th; if (!pthread_create(&th, NULL, keep_display_awake, NULL)) pthread_detach(th); }
        }
        // 着色器抓取：包里没带的着色器（游戏绑定了、映射表里没有的）连控制段和代码区存到这个目录 —— 补表用。
        // 外面设了 DM_NVN_SHDUMP 就用外面的。
        // Shader capture: the shaders the package does not have (the game binds them, the map does not have them) are saved with their control section and code
        // area into this directory, to grow the map with. An outside DM_NVN_SHDUMP wins.
        if (!getenv("DM_NVN_SHDUMP")) setenv("DM_NVN_SHDUMP", shdump.fileSystemRepresentation, 1);
        // 环境开关文件（诊断用：双击起的包没法从外面给环境变量）：一行一个 KEY=VALUE，# 开头是注释；外面已有的环境变量优先
        // Environment switch file (for diagnostics: a double-clicked package cannot be given environment variables from outside): one KEY=VALUE per line, # starts a
        // comment; an environment variable that is already set wins
        NSString *envf = [sup stringByAppendingPathComponent:@"env.txt"];
        NSString *etxt = [NSString stringWithContentsOfFile:envf encoding:NSUTF8StringEncoding error:nil];
        for (NSString *raw in [etxt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSRange eq = [ln rangeOfString:@"="];
            if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
            NSString *k = [ln substringToIndex:eq.location], *v = [ln substringFromIndex:eq.location + 1];
            if (!getenv(k.UTF8String)) { setenv(k.UTF8String, v.UTF8String, 0); LOG("[App] env %s=%s (%s)", k.UTF8String, v.UTF8String, envf.lastPathComponent.UTF8String); }
        }
        static char *av[3]; av[0] = (*argv)[0]; av[1] = strdup(prod.fileSystemRepresentation); av[2] = NULL;   // strdup：autoreleasepool 结束后指针还在
        *argv = av; *argc = 2;
        LOG("[App] running as a packaged .app: the game files %s, the program %s, the saves %s, the log %s, the shaders the package lacks are saved into %s", rom.UTF8String, prod.UTF8String, save.UTF8String, lf.UTF8String, shdump.UTF8String);
        return 1;
    }
}
