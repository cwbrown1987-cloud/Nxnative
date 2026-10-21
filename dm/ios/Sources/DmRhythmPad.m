// Rhythm pad for Rhythm Heaven Groove (profile pad_layout rhythm, iOS 26+): the right half of the screen sends A, the left half
// sends the key the current minigame needs there; an A-only minigame sends A from the whole picture. B sits at the top, halfway
// between the left screen edge and the picture edge; + / - are stacked at the top of the right side bar (+ above -).
// The glass keys use the Liquid Glass material (UIGlassEffect); the zones are invisible hit areas. In a minigame, a pressed zone shows only a small soft glow at the touch point
// and its key symbol just above the finger; there is no zone fill, border or rim. The game has no touch input: the boot caution / title screen uses a hidden A on the right half, and the start
// menu adds swipe navigation on the left half. Other menus turn a tap into A and a swipe into one D-pad press (no zone or label
// drawn); there is no game-touch passthrough.
//
// The host follows the game's own asset loads (dm_touch_layout.c) and publishes kind / left key / extra keys; this view polls the
// generation on a display link, so a scene change swaps the left key without a full view rebuild. All touches go through this view:
// keys are captured here (multi-touch, one key per finger, locked at touch-down), while a menu gesture starts in the free area and
// fires at most one direction pulse per touch. A connected physical controller hides the pad and keeps every button.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include <pthread.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dm_input.h"
#include "front.h"
#include "dm.h"
#include "game_profile.h"
#include "dm_touch_layout.h"
#include "dm_rhythm_pad.h"

@interface DmRhythmPad : UIView
@end

static __weak DmRhythmPad *g_view;

@implementation DmRhythmPad {
    dm_rp_state _st;
    unsigned _gen;
    int _kind, _left, _extra;
    BOOL _padOff;
    float _last_w, _last_h, _last_sl, _last_sr, _last_st, _last_sb;
    CADisplayLink *_link;

    UIView *_controls;
    UIVisualEffectView *_glassB, *_glassPlus, *_glassMinus;
    UILabel *_labelB, *_labelPlus, *_labelMinus;
    NSMutableArray<UIVisualEffectView *> *_extraGlass;
    NSMutableArray<UILabel *> *_extraLabel;
    UIView *_dotL, *_dotR;
    UILabel *_zoneLabelL, *_zoneLabelR;

    NSMapTable<UITouch *, NSNumber *> *_owner;   // touch -> finger slot
    BOOL _slotUsed[16];
    int _zoneOfSlot[16];                          // 0 none, 1 left key zone, 2 A zone (the whole picture in an A-only game)
    CGPoint _point[16];                           // current touch position, so the highlight follows the finger
    UITouch *_game[16];                          // slots forwarded to the game touch screen (menu / physical-controller fallback)
    int _debug;
    uint64_t _lastButtons;
    int _lastTouchN;
}

static UIVisualEffectView *glassView(CGFloat radius) {
    UIGlassEffect *e = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    e.interactive = NO;
    UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:e];
    v.userInteractionEnabled = NO;
    v.clipsToBounds = YES;
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    return v;
}
static UILabel *keyLabel(NSString *text, CGFloat size) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text; l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
    l.textColor = UIColor.whiteColor; l.userInteractionEnabled = NO;
    l.layer.shadowColor = UIColor.blackColor.CGColor; l.layer.shadowOpacity = 0.35f;
    l.layer.shadowRadius = 2; l.layer.shadowOffset = CGSizeMake(0, 1);
    return l;
}
static UIView *touchHighlight(void) {   // small soft glow at the touch point; no half-screen fill or border
    UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
    v.userInteractionEnabled = NO; v.hidden = YES; v.opaque = NO;
    v.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10f];
    v.layer.cornerRadius = 24; v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.shadowColor = UIColor.whiteColor.CGColor;
    v.layer.shadowOpacity = 0.35f;
    v.layer.shadowRadius = 12;
    v.layer.shadowOffset = CGSizeZero;
    return v;
}
static int rp_from_host(int k) {
    switch (k) {
        case DM_TL_B: return DM_RP_KEY_B;
        case DM_TL_LEFT: return DM_RP_KEY_LEFT;
        case DM_TL_RIGHT: return DM_RP_KEY_RIGHT;
        case DM_TL_DOWN: return DM_RP_KEY_DOWN;
        case DM_TL_UP: return DM_RP_KEY_UP;
        default: return DM_RP_KEY_NONE;
    }
}
static uint32_t rp_extra_from_host(uint32_t m) {
    uint32_t r = 0;
    if (m & (1u << DM_TL_LEFT)) r |= 1u << DM_RP_KEY_LEFT;
    if (m & (1u << DM_TL_RIGHT)) r |= 1u << DM_RP_KEY_RIGHT;
    if (m & (1u << DM_TL_DOWN)) r |= 1u << DM_RP_KEY_DOWN;
    if (m & (1u << DM_TL_UP)) r |= 1u << DM_RP_KEY_UP;
    return r;
}
static NSString *hint_text(int key) {
    switch (key) {
        case DM_RP_KEY_B: return @"B";
        case DM_RP_KEY_A: return @"A";
        case DM_RP_KEY_LEFT: return @"\u2190";
        case DM_RP_KEY_RIGHT: return @"\u2192";
        case DM_RP_KEY_DOWN: return @"\u2193";
        case DM_RP_KEY_UP: return @"\u2191";
        default: return @"";
    }
}
static NSString *extra_symbol(int key) {
    switch (key) {
        case DM_RP_KEY_LEFT: return @"chevron.left";
        case DM_RP_KEY_RIGHT: return @"chevron.right";
        case DM_RP_KEY_DOWN: return @"chevron.down";
        case DM_RP_KEY_UP: return @"chevron.up";
        default: return nil;
    }
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        _debug = getenv("DM_RHYTHM_DEBUG") != NULL;
        _owner = [NSMapTable strongToStrongObjectsMapTable];
        _extraGlass = [NSMutableArray array]; _extraLabel = [NSMutableArray array];
        _controls = [[UIView alloc] initWithFrame:self.bounds];
        _controls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _controls.userInteractionEnabled = NO;
        [self addSubview:_controls];
        _dotL = touchHighlight(); _dotR = touchHighlight();
        [_controls addSubview:_dotL]; [_controls addSubview:_dotR];
        _zoneLabelL = keyLabel(@"", 24); _zoneLabelR = keyLabel(@"A", 24);
        for (UILabel *l in @[_zoneLabelL, _zoneLabelR]) {
            l.backgroundColor = UIColor.clearColor;
            l.layer.shadowOpacity = 0.55f; l.layer.shadowRadius = 3;
            l.alpha = 0; l.hidden = NO;   // only the text fades in/out; no badge or zone behind it
            [_controls addSubview:l];
        }
        _glassB = glassView(24); _glassPlus = glassView(24); _glassMinus = glassView(24);
        [_controls addSubview:_glassB]; [_controls addSubview:_glassPlus]; [_controls addSubview:_glassMinus];
        _labelB = keyLabel(@"B", 24); _labelPlus = keyLabel(@"+", 24); _labelMinus = keyLabel(@"\u2212", 24);
        [_controls addSubview:_labelB]; [_controls addSubview:_labelPlus]; [_controls addSubview:_labelMinus];

        _gen = 0; [self updateFromHost:YES];
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 60);
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidDisconnectNotification object:nil];
        [self padsChanged];
    }
    return self;
}
- (void)dealloc {
    [_link invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (!newWindow) [_link invalidate];   // the display link retains its target: break the cycle when the pad leaves the window
}

- (void)publish {
    dm_input_set(_st.buttons, 0, 0, 0, 0);
    if (_debug && _st.buttons != _lastButtons) {
        _lastButtons = _st.buttons;
        LOG("rhythm buttons: %#llx samples=%llu kind=%d", (unsigned long long)_st.buttons,
            (unsigned long long)dm_input_samples(), _kind);
    }
}

- (void)updateFromHost:(BOOL)force {
    unsigned g = dm_touch_layout_gen();
    if (!force && g == _gen) return;
    _gen = g;
    int tk = dm_touch_layout_kind();
    int kind = tk == DM_TL_MENU ? DM_RP_MENU : tk == DM_TL_START ? DM_RP_A_RIGHT_NAV :
               tk == DM_TL_A_RIGHT ? DM_RP_A_RIGHT : DM_RP_GAME;
    int left = rp_from_host(dm_touch_layout_left());
    uint32_t extra = rp_extra_from_host(dm_touch_layout_extra());
    BOOL changed = force || kind != _kind || left != _left || (int)extra != _extra;
    _kind = kind; _left = left; _extra = (int)extra;
    if (!changed) return;
    [self cancelAll];
    dm_rp_set_layout(&_st, _kind, _left, (uint32_t)_extra);
    [self rebuildExtraViews];
    [self updateZoneVisuals];
    const char *kn = _kind == DM_RP_MENU ? "menu" : _kind == DM_RP_A_RIGHT ? "a-right" :
                     _kind == DM_RP_A_RIGHT_NAV ? "start" : "game";
    LOG("rhythm pad: %s left=%s%s", kn, hint_text(_left).UTF8String,
        _extra ? " + extra" : "");
    [self setNeedsLayout];
    [self publish];
}

- (void)tick:(CADisplayLink *)l {
    (void)l;
    if (dm_rp_tick(&_st)) [self publish];   // a tap / swipe pulse ended; keep it long enough for the game's next Npad read
    [self updateFromHost:NO];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets in = self.safeAreaInsets;
    float w = self.bounds.size.width, h = self.bounds.size.height;
    if (_last_w != w || _last_h != h || _last_sl != in.left || _last_sr != in.right || _last_st != in.top || _last_sb != in.bottom) {
        _last_w = w; _last_h = h; _last_sl = in.left; _last_sr = in.right; _last_st = in.top; _last_sb = in.bottom;
        [self cancelAll];
        dm_rp_init(&_st, w, h, _kind, _left, (uint32_t)_extra, in.left, in.right, in.top, in.bottom);
        [self rebuildExtraViews];
        [self updateZoneVisuals];
        [self publish];
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    const dm_rp_layout *l = &_st.layout;
    _glassB.frame = CGRectMake(l->b.x - l->b.r, l->b.y - l->b.r, 2 * l->b.r, 2 * l->b.r); _glassB.layer.cornerRadius = l->b.r;
    _glassPlus.frame = CGRectMake(l->plus.x - l->plus.r, l->plus.y - l->plus.r, 2 * l->plus.r, 2 * l->plus.r); _glassPlus.layer.cornerRadius = l->plus.r;
    _glassMinus.frame = CGRectMake(l->minus.x - l->minus.r, l->minus.y - l->minus.r, 2 * l->minus.r, 2 * l->minus.r); _glassMinus.layer.cornerRadius = l->minus.r;
    _labelB.frame = _glassB.frame;
    // The system font's + / − glyphs sit about 2 pt below the line-box centre; lift only those two labels so their ink is centred in the glass.
    _labelPlus.frame = CGRectOffset(_glassPlus.frame, 0, -2);
    _labelMinus.frame = CGRectOffset(_glassMinus.frame, 0, -2);
    for (int i = 0; i < l->n_extra && i < (int)_extraGlass.count; i++) {
        const dm_rp_button *b = &l->extra[i];
        _extraGlass[i].frame = CGRectMake(b->x - b->r, b->y - b->r, 2 * b->r, 2 * b->r); _extraGlass[i].layer.cornerRadius = b->r;
        _extraLabel[i].frame = _extraGlass[i].frame;
        for (UIView *sv in _extraLabel[i].subviews) sv.frame = _extraLabel[i].bounds;   // the SF Symbol inside the glass key
    }
    [self updateZoneVisuals];
    [CATransaction commit];
}

- (void)rebuildExtraViews {
    for (UIVisualEffectView *v in _extraGlass) [v removeFromSuperview];
    for (UILabel *l in _extraLabel) [l removeFromSuperview];
    [_extraGlass removeAllObjects]; [_extraLabel removeAllObjects];
    CGFloat u = self.bounds.size.height / 430.0; if (u > 1.3) u = 1.3; if (u < 0.6) u = 0.6;
    for (int i = 0; i < _st.layout.n_extra; i++) {
        int key = _st.layout.extra[i].key;
        UIVisualEffectView *g = glassView(24 * u);
        UILabel *l = keyLabel(nil, 20 * u);
        UIImage *im = [UIImage systemImageNamed:extra_symbol(key)];
        if (im) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:im];
            iv.tintColor = UIColor.whiteColor; iv.contentMode = UIViewContentModeScaleAspectFit; iv.frame = l.bounds;
            iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [l addSubview:iv];
        }
        [_controls addSubview:g]; [_controls addSubview:l];
        [_extraGlass addObject:g]; [_extraLabel addObject:l];
    }
    [self setNeedsLayout];
}

- (void)showZoneLabel:(UILabel *)label {
    if (label.alpha >= 0.80f) return;
    [label.layer removeAllAnimations];
    label.hidden = NO;
    [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{ label.alpha = 0.82f; } completion:nil];
}
- (void)hideZoneLabel:(UILabel *)label {
    if (label.alpha <= 0.01f) return;
    [label.layer removeAllAnimations];
    [UIView animateWithDuration:0.20 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{ label.alpha = 0; } completion:nil];
}
- (void)placeTouchDot:(UIView *)dot label:(UILabel *)label at:(CGPoint)p {
    UIEdgeInsets in = self.safeAreaInsets;
    const CGFloat r = 24, lw = 64, lh = 30;
    CGFloat x = fminf(fmaxf(p.x, in.left + lw / 2 + 6), self.bounds.size.width - in.right - lw / 2 - 6);
    CGFloat y = p.y - r - 8 - lh / 2;   // above the finger, not under it
    CGFloat miny = in.top + lh / 2 + 6;
    if (y < miny) y = miny;
    dot.frame = CGRectMake(p.x - r, p.y - r, 2 * r, 2 * r);
    label.frame = CGRectMake(x - lw / 2, y - lh / 2, lw, lh);
    dot.hidden = NO;
}
- (void)updateZoneVisuals {
    BOOL game = _kind == DM_RP_GAME;
    int left = -1, right = -1;
    if (game) for (int i = 0; i < 16; i++) {
        if (_zoneOfSlot[i] == 1 && left < 0) left = i;
        else if (_zoneOfSlot[i] == 2 && right < 0) right = i;
    }
    if (left < 0) { _dotL.hidden = YES; [self hideZoneLabel:_zoneLabelL]; }
    else {
        _zoneLabelL.text = hint_text(_left);
        [self placeTouchDot:_dotL label:_zoneLabelL at:_point[left]];
        [self showZoneLabel:_zoneLabelL];
    }
    if (right < 0) { _dotR.hidden = YES; [self hideZoneLabel:_zoneLabelR]; }
    else {
        _zoneLabelR.text = @"A";
        [self placeTouchDot:_dotR label:_zoneLabelR at:_point[right]];
        [self showZoneLabel:_zoneLabelR];
    }
}

// ---- touches ----
- (int)freeSlot {
    for (int i = 0; i < 16; i++) if (!_slotUsed[i]) return i;
    return -1;
}
- (void)cancelAll {
    for (int i = 0; i < 16; i++) { _slotUsed[i] = NO; _game[i] = nil; _zoneOfSlot[i] = 0; _point[i] = CGPointZero; }
    [_owner removeAllObjects];
    dm_rp_cancel_all(&_st);
    dm_touch_set(NULL, 0);
    _lastTouchN = 0;
    [self publish];
    [self updateZoneVisuals];
}
- (void)pushGame {
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;   // the 16:9 picture centred by front_ios.m
    CGFloat x0 = (b.size.width - w) / 2, y0 = (b.size.height - h) / 2;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
    if (_debug && n != _lastTouchN) { _lastTouchN = n; LOG("rhythm game touch: %d", n); }
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    (void)e;
    BOOL game = NO;
    for (UITouch *t in ts) {
        int slot = [self freeSlot]; if (slot < 0) continue;
        _slotUsed[slot] = YES; [_owner setObject:@(slot) forKey:t];
        CGPoint p = [t locationInView:self]; _point[slot] = p;
        int k = DM_RP_INERT;
        if (_padOff) { _game[slot] = t; game = YES; }
        else {
            k = dm_rp_begin(&_st, slot, p.x, p.y);
            // The game never reads the touch screen: a menu free area is tracked as a gesture, not forwarded.
        }
        int zone = 0;
        if (!_padOff && _kind == DM_RP_GAME) {
            CGFloat half = self.bounds.size.width / 2;
            if (k == DM_RP_KEY_A && (_left == DM_RP_KEY_NONE || p.x >= half)) zone = 2;   // A-only: show A anywhere in the picture
            else if (_left != DM_RP_KEY_NONE && k == _left && p.x < half) zone = 1;
        }
        _zoneOfSlot[slot] = zone;
        if (_debug) LOG("rhythm touch: down slot=%d %.1f,%.1f key=%d kind=%d zone=%d", slot, p.x, p.y, k, _kind, zone);
    }
    if (game) [self pushGame];
    [self publish];
    [self updateZoneVisuals];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    (void)e;
    BOOL game = NO, moved = NO;
    for (UITouch *t in ts) {
        NSNumber *n = [_owner objectForKey:t]; if (!n) continue;
        int slot = n.intValue;
        CGPoint p = [t locationInView:self]; _point[slot] = p;
        if (_game[slot]) { game = YES; continue; }   // keys stay locked at the key the finger went down on
        int k = dm_rp_move(&_st, slot, p.x, p.y);
        if (k) {
            moved = YES;
            if (_debug) LOG("rhythm gesture: slot=%d %s", slot, hint_text(k).UTF8String);
        }
    }
    if (game) [self pushGame];
    if (game || moved) [self publish];
    [self updateZoneVisuals];
}
- (void)endTouches:(NSSet<UITouch *> *)ts fire:(BOOL)fire {
    BOOL game = NO;
    for (UITouch *t in ts) {
        NSNumber *n = [_owner objectForKey:t]; if (!n) continue;
        int slot = n.intValue;
        if (_game[slot]) { _game[slot] = nil; game = YES; }
        if (fire) dm_rp_end(&_st, slot);
        else dm_rp_cancel(&_st, slot);   // a system gesture must not turn into a tap
        _slotUsed[slot] = NO;
        _zoneOfSlot[slot] = 0;
        _point[slot] = CGPointZero;
        [_owner removeObjectForKey:t];
        if (_debug) LOG("rhythm touch: up slot=%d%s", slot, fire ? "" : " (cancelled)");
    }
    if (game) [self pushGame];
    [self publish];
    [self updateZoneVisuals];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { (void)e; [self endTouches:ts fire:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { (void)e; [self endTouches:ts fire:NO]; }

// ---- physical controllers ----
static int32_t pad_axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
- (void)readPad:(GCExtendedGamepad *)g {   // by position, as on a Switch controller (bottom B, right A, top X, left Y)
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= bit
    K(g.buttonB, DM_BTN_A); K(g.buttonA, DM_BTN_B); K(g.buttonY, DM_BTN_X); K(g.buttonX, DM_BTN_Y);
    K(g.leftShoulder, DM_BTN_L); K(g.rightShoulder, DM_BTN_R); K(g.leftTrigger, DM_BTN_ZL); K(g.rightTrigger, DM_BTN_ZR);
    K(g.buttonMenu, DM_BTN_PLUS); if (g.buttonOptions) K(g.buttonOptions, DM_BTN_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, DM_BTN_LS);
    if (g.rightThumbstickButton) K(g.rightThumbstickButton, DM_BTN_RS);
    K(g.dpad.left, DM_BTN_LEFT); K(g.dpad.up, DM_BTN_UP); K(g.dpad.right, DM_BTN_RIGHT); K(g.dpad.down, DM_BTN_DOWN);
    #undef K
    dm_pad_set(m, pad_axis(g.leftThumbstick.xAxis.value), pad_axis(g.leftThumbstick.yAxis.value),
               pad_axis(g.rightThumbstick.xAxis.value), pad_axis(g.rightThumbstick.yAxis.value));
}
- (void)padsChanged {
    BOOL any = NO;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) {
        any = YES;
        __weak DmRhythmPad *ws = self;
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; [ws readPad:g]; };
        [self readPad:c.extendedGamepad];
    }
    if (!any) dm_pad_set(0, 0, 0, 0, 0);
    if (_debug) LOG("rhythm pad: controller %s", any ? "connected (touch pad hidden)" : "none");
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_padOff = any; self->_controls.hidden = any;
        [self cancelAll];
    });
}
- (void)reset { dm_pad_set(0, 0, 0, 0, 0); [self cancelAll]; }
@end

UIView *dm_rhythm_pad_view(CGRect frame) {
    DmRhythmPad *v = [[DmRhythmPad alloc] initWithFrame:frame];
    g_view = v; return v;
}
void dm_rhythm_pad_reset(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
}
