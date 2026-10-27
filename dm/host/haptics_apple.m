// Core Haptics adapts the game's bands; it cannot reproduce the Switch's exact waveforms.
// All engines and players belong to one serial queue. Guest threads enqueue ordered snapshots only.
#import "haptics_apple.h"
#import <CoreHaptics/CoreHaptics.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#else
#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDManager.h>
#endif
#include <math.h>
#include <pthread.h>
#include <time.h>

@interface DmRumbleChannel : NSObject
@property(nonatomic) CHHapticEngine *engine;
@property(nonatomic) id<CHHapticAdvancedPatternPlayer> pattern;
@property(nonatomic, copy) CHHapticEngine *(^createEngine)(NSError **);
@property(nonatomic, copy) NSString *target;
@property(nonatomic, copy) void (^fallback)(NSTimeInterval);
@property(nonatomic) int player;
@property(nonatomic) uint64_t generation;
@property(nonatomic) uint64_t silenceGeneration;
@property(nonatomic) NSTimeInterval retryAfter;
@property(nonatomic) unsigned failures;
- (void)apply:(dm_haptic_level)level;
- (void)stop;
@end

static dispatch_queue_t queue;
static NSMutableArray<DmRumbleChannel *> *channels[DM_PLAYERS];
static GCController *controllers[DM_PLAYERS];
#if TARGET_OS_IPHONE
static BOOL phoneSupported;
#endif
static float gain = 1;
static pthread_mutex_t routeLock = PTHREAD_MUTEX_INITIALIZER;
static unsigned errors;
static NSTimeInterval now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void report(NSError *e, NSString *target, const char *stage) {
    if (++errors <= 8 || errors % 64 == 0) {
        fprintf(stderr, "[RED] haptics: %s %s: %s (%s %ld)\n", target.UTF8String, stage,
                e.localizedDescription.UTF8String ?: "engine unavailable", e.domain.UTF8String ?: "no error", (long)e.code);
        NSError *underlying = e.userInfo[NSUnderlyingErrorKey];
        if (underlying) fprintf(stderr, "[RED] haptics: underlying %s %ld: %s\n", underlying.domain.UTF8String,
                                (long)underlying.code, underlying.userInfo[NSDebugDescriptionErrorKey] ?
                                [underlying.userInfo[NSDebugDescriptionErrorKey] UTF8String] : underlying.localizedDescription.UTF8String);
    }
}

@implementation DmRumbleChannel
- (void)stop {
    self.generation++; self.silenceGeneration++;
    self.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; }; self.engine.resetHandler = ^{};
    [self.pattern stopAtTime:CHHapticTimeImmediate error:nil]; self.pattern = nil;
    [self.engine stopWithCompletionHandler:nil];   // the engine stays: the next effect restarts it
}
- (void)failed:(NSError *)error stage:(const char *)stage {
    report(error, self.target, stage);
    [self stop]; self.engine = nil;   // A failed helper connection must not be reused for every later vibration.
    self.failures = MIN(self.failures + 1, 4u);
    self.retryAfter = now() + (1u << (self.failures - 1));
    dm_haptics_clear(self.player);
}
- (void)engineFailed:(NSError *)error stage:(const char *)stage {
    [self failed:error stage:stage];
    // An engine that cannot be made or started moves a split route to the default locality at once;
    // a single player or parameter failure (a service reset, say) is retried on the same handle (playerFailed).
    if (self.fallback) self.fallback(self.retryAfter);
}
- (void)playerFailed:(NSError *)error stage:(const char *)stage {
    [self failed:error stage:stage];
    // A handle whose player fails twice in a row, with no effect in between, is no passing service reset: on macOS 27.0.1 a DualShock 4's
    // left handle answered every create player with NSCocoaErrorDomain 4097 (issue #219 logged it too), and each failure cleared the
    // player's output, so the right handle stayed silent as well. Move the split route to the default locality, as for an engine failure.
    if (self.failures >= 2 && self.fallback) self.fallback(self.retryAfter);
}
- (void)apply:(dm_haptic_level)level {
    uint64_t silence = ++self.silenceGeneration;
    NSError *error = nil;
    if (!self.pattern) {
        if (level.intensity == 0) return;
        if (now() < self.retryAfter) {
            // Discard this effect, so an identical fresh send after the backoff is not deduplicated away.
            dm_haptics_clear(self.player); return;
        }
        if (!self.engine) {
            self.engine = self.createEngine(&error);
            if (!self.engine) { [self engineFailed:error stage:"create engine"]; return; }
            self.engine.playsHapticsOnly = YES; self.engine.autoShutdownEnabled = NO;
        }
        __weak DmRumbleChannel *weak = self;
        uint64_t generation = ++self.generation;
        void (^reset)(void) = ^{
            dispatch_async(queue, ^{
                DmRumbleChannel *c = weak; if (!c || c.generation != generation) return;
                [c stop];
                dm_haptics_clear(c.player);   // queued effects from before an interruption cannot restart
            });
        };
        self.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; reset(); };
        self.engine.resetHandler = reset;
        // Startup can itself fail or reset the service: install handlers before contacting it.
        if (![self.engine startAndReturnError:&error]) { [self engineFailed:error stage:"start engine"]; return; }
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]
        ] relativeTime:0 duration:30];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        self.pattern = pattern ? [self.engine createAdvancedPlayerWithPattern:pattern error:&error] : nil;
        if (!self.pattern) { [self playerFailed:error stage:"create player"]; return; }
        self.pattern.loopEnabled = YES;
        self.pattern.isMuted = YES;
        if (![self.pattern startAtTime:CHHapticTimeImmediate error:&error]) { [self playerFailed:error stage:"start player"]; return; }
    }
    // Controls live outside the loop: the loop boundary never replays an initial intensity.
    NSArray *parameters = @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:level.intensity relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:level.sharpness - 0.5f relativeTime:0]
    ];
    if (![self.pattern sendParameters:parameters atTime:CHHapticTimeImmediate error:&error]) {
        [self failed:error stage:"send parameters"]; return;
    }
    self.failures = 0;
    self.pattern.isMuted = NO;
    if (level.intensity == 0) {
        // Reuse a warm player for nearby pulses, then release idle hardware. This never times out an active effect.
        __weak DmRumbleChannel *weak = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), queue, ^{
            DmRumbleChannel *c = weak; if (c && c.silenceGeneration == silence) [c stop];
        });
    }
}
@end

#if !TARGET_OS_IPHONE
// A DualShock 4, or a controller that presents itself as one (a GameSir Cyclone over Bluetooth: Sony 054C / 05C4), whose Core Haptics
// helper fails on every locality (NSCocoaErrorDomain 4097 on macOS 27.0.1, a plain test app too) still takes the effects report that
// SDL's hidapi driver sends, as the Switch emulators do: 0x11 over Bluetooth (78 bytes, CRC32 over 0xA2 and the first 74 bytes, rumble
// only, so the light bar is left alone), 0x05 over USB (32 bytes). Two channels share one report: the strong (left) and weak (right) motor.
typedef struct { IOHIDDeviceRef dev; BOOL bluetooth; uint8_t motor[2], sent[2]; } ds4_out;
static ds4_out ds4[DM_PLAYERS];
static IOHIDManagerRef hidManager;
static uint32_t ds4_crc(const uint8_t *p, size_t n) {
    uint32_t c = ~0u;
    while (n--) { c ^= *p++; for (int k = 0; k < 8; k++) c = c >> 1 ^ (0xEDB88320u & -(c & 1)); }
    return ~c;
}
static void ds4_send(int p) {
    ds4_out *o = &ds4[p]; uint8_t r[78] = {0}; size_t n;
    if (o->bluetooth) {
        r[0] = 0x11; r[1] = 0xC4; r[3] = 0x01; r[6] = o->motor[1]; r[7] = o->motor[0]; n = 78;
        uint8_t c[75] = {0xA2}; memcpy(c + 1, r, 74);
        uint32_t crc = ds4_crc(c, sizeof c); r[74] = crc; r[75] = crc >> 8; r[76] = crc >> 16; r[77] = crc >> 24;
    } else { r[0] = 0x05; r[1] = 0x01; r[4] = o->motor[1]; r[5] = o->motor[0]; n = 32; }
    IOReturn e = IOHIDDeviceSetReport(o->dev, kIOHIDReportTypeOutput, r[0], r, n);
    if (e != kIOReturnSuccess) { if (++errors <= 8 || errors % 64 == 0) fprintf(stderr, "[RED] haptics: DualShock 4 effects report: IOReturn 0x%x\n", e); return; }
    o->sent[0] = o->motor[0]; o->sent[1] = o->motor[1];
}
// The emulators' mapping (as Ryujinx's NpadController feeds SDL): the strong motor follows the low band and the weak one the high band,
// mostly from the left and the right motor respectively, linearly. Core Haptics' combined level (dm_haptics_level: both bands, root of
// the sum of squares) ran Mario Kart 8 Deluxe's quiet driving texture at 30–90 of 255 on the DS4's rotating motors: felt as rumble that
// never stopped after a crash, and that went on for seconds in the menus while the game faded it out
// DM_DS4_RUMBLE_MIN (0 to 0.9, default 0): amplitudes below it stay silent and the rest is stretched over the full range. Mario Kart 8
// Deluxe drives its low band at 0.1–0.4 all race long (about 30 changes a second, with 0.84 peaks every few seconds); on a Joy-Con's
// resonant actuator that is a texture, on the DS4's rotating motors a rumble that never lets up
static float ds4_min;
static uint8_t ds4_byte(float x) {
    x = isfinite(x) ? fmaxf(0, fminf(1, x)) : 0;
    x = x <= ds4_min ? 0 : (x - ds4_min) / (1 - ds4_min);
    return (uint8_t)lrintf(x * 255);
}
static void ds4_apply(dm_haptic_state s) {
    ds4_out *o = &ds4[s.player];
    if (!o->dev) return;
    const dm_vibration *l = &s.motor[0], *r = &s.motor[1];
    o->motor[0] = ds4_byte((0.85f * l->amplitude_low + 0.15f * r->amplitude_low) * gain);
    o->motor[1] = ds4_byte((0.15f * l->amplitude_high + 0.85f * r->amplitude_high) * gain);
    if (o->motor[0] == o->sent[0] && o->motor[1] == o->sent[1]) return;
    ds4_send(s.player);
    if (getenv("DM_RUMBLE_LOG")) fprintf(stderr, "rumble: DualShock 4 report: strong %u weak %u (left low %.2f@%.0f high %.2f@%.0f, right low %.2f@%.0f high %.2f@%.0f)\n",
                                         o->sent[0], o->sent[1], l->amplitude_low, l->frequency_low, l->amplitude_high, l->frequency_high,
                                         r->amplitude_low, r->frequency_low, r->amplitude_high, r->frequency_high);
}
static void ds4_release(int p) {
    ds4_out *o = &ds4[p];
    if (o->dev) { o->motor[0] = o->motor[1] = 0; if (o->sent[0] || o->sent[1]) ds4_send(p); CFRelease(o->dev); }
    *o = (ds4_out){0};
}
@interface DmDs4Channel : DmRumbleChannel
@property(nonatomic) int motor;   // 0 the strong (left) motor, 1 the weak (right) one
@end
@implementation DmDs4Channel
- (void)apply:(dm_haptic_level)level { (void)level; }   // the route takes both motors' raw values at once (ds4_apply)
- (void)stop {
    ds4_out *o = &ds4[self.player];
    o->motor[self.motor] = 0;
    if (o->dev && (o->sent[0] || o->sent[1]) && !o->motor[0] && !o->motor[1]) ds4_send(self.player);
}
@end
// Only a controller GameController calls a DualShock 4, and only while one Sony DualShock 4 HID device is there to address
static BOOL ds4_route(int p, GCController *controller) {
    if (![controller respondsToSelector:@selector(productCategory)] || ![controller.productCategory isEqualToString:GCProductCategoryDualShock4]) return NO;
    if (!hidManager) {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        IOHIDManagerSetDeviceMatching(hidManager, (__bridge CFDictionaryRef)@{@kIOHIDVendorIDKey: @0x054C});
        if (IOHIDManagerOpen(hidManager, kIOHIDOptionsTypeNone) != kIOReturnSuccess) { CFRelease(hidManager); hidManager = NULL; return NO; }
    }
    NSSet *devices = CFBridgingRelease(IOHIDManagerCopyDevices(hidManager));
    for (id d in devices) {
        IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)d;
        int pid = [(__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey)) intValue];
        if (pid != 0x05C4 && pid != 0x09CC && pid != 0x0BA0) continue;   // DualShock 4 v1, v2, the USB wireless adapter
        ds4_release(p);
        ds4[p].dev = (IOHIDDeviceRef)CFRetain(dev);
        ds4[p].bluetooth = [(__bridge NSString *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey)) isEqualToString:@"Bluetooth"];
        for (DmRumbleChannel *old in channels[p]) [old stop];
        channels[p] = [NSMutableArray new];
        for (int m = 0; m < 2; m++) { DmDs4Channel *c = [DmDs4Channel new]; c.player = p; c.motor = m; c.target = @"DualShock 4 report"; [channels[p] addObject:c]; }
        dm_haptics_route(p, 1);
        fprintf(stderr, "haptics: player %d rumble through the DualShock 4 effects report (%s, product 0x%04x)\n",
                p + 1, ds4[p].bluetooth ? "Bluetooth" : "USB", pid);
        return YES;
    }
    return NO;
}
#endif

static void apply(dm_haptic_state s) {
    dispatch_async(queue, ^{ @autoreleasepool {
        if (s.epoch != dm_haptics_epoch(s.player)) return;
        NSArray<DmRumbleChannel *> *out = channels[s.player];
#if !TARGET_OS_IPHONE
        if ([out.firstObject isKindOfClass:DmDs4Channel.class]) { ds4_apply(s); return; }
#endif
        for (NSUInteger i = 0; i < out.count; i++) {
            if (s.epoch != dm_haptics_epoch(s.player)) break;   // a failed channel may replace this route
            dm_haptic_level level = out.count == 2 ? dm_haptics_level(&s.motor[i], 1, gain) : dm_haptics_level(s.motor, 2, gain);
            [out[i] apply:level];
        }
    } });
}
static void add_engine(int p, NSString *target, CHHapticEngine *(^create)(NSError **)) {
    DmRumbleChannel *c = [DmRumbleChannel new]; c.createEngine = create; c.target = target; c.player = p;
    [channels[p] addObject:c];
}
static void default_controller(int p, GCController *controller, NSTimeInterval retryAfter) {
    GCDeviceHaptics *h = controller.haptics;
    add_engine(p, @"controller default", ^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:GCHapticsLocalityDefault]; });
    channels[p].lastObject.retryAfter = retryAfter;
#if !TARGET_OS_IPHONE
    // The last resort on the Mac: a DualShock 4 whose default locality fails too gets its effects report instead (ds4_route);
    // any other controller keeps retrying the default locality after the backoff
    __weak NSArray *route = channels[p];
    channels[p].lastObject.fallback = ^(NSTimeInterval after) { (void)after; if (route && channels[p] == route) ds4_route(p, controller); };
#endif
}
static void configure(int p, GCController *controller) {
    for (DmRumbleChannel *c in channels[p]) [c stop];
    channels[p] = [NSMutableArray new];
#if !TARGET_OS_IPHONE
    ds4_release(p);
    // A DualShock 4 takes its effects report at once, as SDL drives it: a controller that only presents itself as one (GameSir Cyclone)
    // fails Core Haptics on every locality, and walking the handle and default routes first lost the first effects of a session
    if (controller && ds4_route(p, controller)) return;
#endif
    if (controller) {
        GCDeviceHaptics *h = controller.haptics;
        NSSet *localities = h.supportedLocalities;
        if ([localities containsObject:GCHapticsLocalityLeftHandle] && [localities containsObject:GCHapticsLocalityRightHandle]) {
            add_engine(p, @"controller left handle", ^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:GCHapticsLocalityLeftHandle]; });
            add_engine(p, @"controller right handle", ^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:GCHapticsLocalityRightHandle]; });
            // Advertised handle localities can still fail to start. Fall back to the standard
            // controller engine, once, rather than keeping two unusable helper connections.
            __weak NSArray *route = channels[p];
            for (DmRumbleChannel *c in channels[p]) c.fallback = ^(NSTimeInterval retryAfter) {
                if (!route || channels[p] != route) return;
                for (DmRumbleChannel *old in channels[p]) [old stop];
                channels[p] = [NSMutableArray new];
                default_controller(p, controller, retryAfter);
                dm_haptics_route(p, 1);
                fprintf(stderr, "haptics: player %d retrying with the default controller locality\n", p + 1);
            };
        }
        else if (localities.count) default_controller(p, controller, 0);
        fprintf(stderr, "haptics: player %d controller %s, localities %s, %lu channels\n", p + 1,
                controller.vendorName.UTF8String ?: "unknown", [[localities.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "].UTF8String ?: "none", (unsigned long)channels[p].count);
    }
#if TARGET_OS_IPHONE
    else if (!p && phoneSupported) {
        // Do not initialize the phone's engine before the game's audio session is active.
        add_engine(p, @"phone", ^CHHapticEngine *(NSError **e) { return [[CHHapticEngine alloc] initWithAudioSession:AVAudioSession.sharedInstance error:e]; });
    }
#endif
    dm_haptics_route(p, channels[p].count != 0);
}
void dm_haptics_apple_controller(int p, GCController *controller) {
    if (!queue || p < 0 || p >= DM_PLAYERS) return;
    pthread_mutex_lock(&routeLock);
    if (controllers[p] != controller) {
        controllers[p] = controller;
        dm_haptics_route(p, 0);   // invalidate queued work before changing hardware
        dispatch_sync(queue, ^{ configure(p, controller); });
    }
    pthread_mutex_unlock(&routeLock);
}
static void suspend(unsigned reason, BOOL on) {
    dm_haptics_suspend(reason, on);
    void (^stop)(void) = ^{
        for (int p = 0; p < DM_PLAYERS; p++) for (DmRumbleChannel *c in channels[p]) [c stop];
    };
    if (on) { if (dispatch_get_specific(&queue)) stop(); else dispatch_sync(queue, stop); }
}
void dm_haptics_apple_shutdown(void) {
    if (queue) suspend(DM_HAPTICS_INACTIVE, YES);
}
void dm_haptics_apple_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("dm.rumble", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, &queue, &queue, NULL);
        const char *e = getenv("DM_RUMBLE_GAIN");
        if (e) { float v = strtof(e, NULL); if (isfinite(v)) gain = fmaxf(0, fminf(3, v)); }
#if !TARGET_OS_IPHONE
        e = getenv("DM_DS4_RUMBLE_MIN");
        if (e) { float v = strtof(e, NULL); if (isfinite(v)) ds4_min = fmaxf(0, fminf(0.9f, v)); }
#endif
        e = getenv("DM_RUMBLE");
        dm_haptics_init(apply, !e || atoi(e) != 0);
#if TARGET_OS_IPHONE
        phoneSupported = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
#endif
        dispatch_sync(queue, ^{ configure(0, nil); });
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
#if TARGET_OS_IPHONE
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; suspend(DM_HAPTICS_INACTIVE, YES); }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; suspend(DM_HAPTICS_INACTIVE, NO); }];
        [nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_haptics_apple_shutdown(); }];
        [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            suspend(DM_HAPTICS_INTERRUPTED, [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan);
        }];
        [nc addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            (void)n; dm_haptics_clear(0);
        }];
#else
        [nc addObserverForName:NSApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; suspend(DM_HAPTICS_INACTIVE, YES); }];
        [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; suspend(DM_HAPTICS_INACTIVE, NO); }];
        [nc addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_haptics_apple_shutdown(); }];
#endif
        atexit(dm_haptics_apple_shutdown);
    });
}
