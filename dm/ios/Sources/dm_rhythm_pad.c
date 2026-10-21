#include "dm_rhythm_pad.h"
#include "../../host/dm_input.h"
#include <math.h>
#include <string.h>

static float dist2(float ax, float ay, float bx, float by) {
    float dx = ax - bx, dy = ay - by; return dx * dx + dy * dy;
}
static int hit_button(const dm_rp_button *b, float x, float y) {
    if (!b->key) return 0;
    float r = b->r * 1.35f;   // generous target: rhythm input does not need pixel aim
    return dist2(x, y, b->x, b->y) <= r * r;
}

uint64_t dm_rp_key_bit(int key) {
    switch (key) {
        case DM_RP_KEY_B: return DM_BTN_B;
        case DM_RP_KEY_A: return DM_BTN_A;
        case DM_RP_KEY_PLUS: return DM_BTN_PLUS;
        case DM_RP_KEY_MINUS: return DM_BTN_MINUS;
        case DM_RP_KEY_LEFT: return DM_BTN_LEFT;
        case DM_RP_KEY_RIGHT: return DM_BTN_RIGHT;
        case DM_RP_KEY_DOWN: return DM_BTN_DOWN;
        case DM_RP_KEY_UP: return DM_BTN_UP;
        default: return 0;
    }
}

void dm_rp_layout_make(dm_rp_layout *l, float w, float h, int kind, int left_key, uint32_t extra_mask,
                       float sl, float sr, float st, float sb) {
    memset(l, 0, sizeof *l);
    l->width = w; l->height = h; l->kind = kind; l->left_key = left_key;
    l->safe_l = sl; l->safe_r = sr; l->safe_t = st; l->safe_b = sb;
    float u = h / 430.0f; if (u > 1.3f) u = 1.3f; if (u < 0.6f) u = 0.6f;   // same unit as DmGamepad, with a floor for small screens
    float inset = 14 * u, gap = 6 * u;
    float rS = 24 * u, rB = rS;   // B matches the + / - buttons; + sits above -
    // The 16:9 picture is centred; put the side keys halfway between the screen edge and its edge, along the
    // top edge as before (B and + share the top row, - below +). A full-width picture leaves no side bar, so
    // fall back to the screen edge.
    float game_w = w < h * 16.0f / 9.0f ? w : h * 16.0f / 9.0f;
    float side_x = (w - game_w) * 0.25f;
    if (side_x < inset + rS) side_x = inset + rS;
    float top = st + inset + rS;
    l->b = (dm_rp_button){side_x, top, rB, DM_RP_KEY_B};
    l->plus = (dm_rp_button){w - side_x, top, rS, DM_RP_KEY_PLUS};
    l->minus = (dm_rp_button){l->plus.x, l->plus.y + 2 * rS + gap, rS, DM_RP_KEY_MINUS};
    static const int order[] = {DM_RP_KEY_LEFT, DM_RP_KEY_RIGHT, DM_RP_KEY_DOWN, DM_RP_KEY_UP};
    for (int i = 0; i < 4; i++) if (extra_mask & (1u << order[i])) {
        int n = l->n_extra++;
        l->extra[n] = (dm_rp_button){sl + inset + rS + n * (2 * rS + gap), h - sb - inset - rS, rS, order[i]};
    }
}

int dm_rp_hit(const dm_rp_layout *l, float x, float y) {
    if (x < 0 || y < 0 || x >= l->width || y >= l->height) return DM_RP_INERT;
    if (hit_button(&l->b, x, y)) return DM_RP_KEY_B;
    if (hit_button(&l->minus, x, y)) return DM_RP_KEY_MINUS;
    if (hit_button(&l->plus, x, y)) return DM_RP_KEY_PLUS;
    for (int i = 0; i < l->n_extra; i++) if (hit_button(&l->extra[i], x, y)) return l->extra[i].key;
    if (l->kind == DM_RP_MENU) return DM_RP_GESTURE;   // menu free area: tap/swipe, no game touch passthrough
    if (l->kind == DM_RP_A_RIGHT) return x >= l->width / 2 ? DM_RP_KEY_A : DM_RP_INERT;   // caution/title: hidden A on the right
    if (l->kind == DM_RP_A_RIGHT_NAV && x < l->width / 2) return DM_RP_GESTURE;   // start menu: A right, gestures left
    if (l->kind == DM_RP_GAME && l->left_key == DM_RP_KEY_NONE) return DM_RP_KEY_A;   // A-only minigame: the whole picture is A
    if (x < l->width / 2) return l->left_key;
    return DM_RP_KEY_A;
}

#define RP_PULSE_FRAMES 8
static float swipe_min(const dm_rp_layout *l) {
    float m = l->height * 0.06f;   // a deliberate swipe, not the small jitter of a tap
    if (m < 22) m = 22;
    if (m > 36) m = 36;
    return m;
}
static void pulse_key(dm_rp_state *s, int key) {
    uint64_t bit = dm_rp_key_bit(key);
    if (!bit) return;
    s->pulse |= bit;
    s->pulse_frames = RP_PULSE_FRAMES;
}
static void recompute(dm_rp_state *s) {
    uint64_t m = s->pulse;
    for (int k = 1; k < DM_RP_KEY_COUNT; k++) if (s->press_count[k] > 0) m |= dm_rp_key_bit(k);
    s->buttons = m;
}

static void clear(dm_rp_state *s) {
    for (int i = 0; i < 16; i++) {
        s->finger_key[i] = 0;
        s->gesture_active[i] = s->gesture_fired[i] = 0;
        s->touch_x[i] = s->touch_y[i] = 0;
    }
    for (int k = 0; k < DM_RP_KEY_COUNT; k++) s->press_count[k] = 0;
    s->pulse = 0; s->pulse_frames = 0;
    s->buttons = 0;
}

void dm_rp_init(dm_rp_state *s, float w, float h, int kind, int left_key, uint32_t extra_mask,
                float sl, float sr, float st, float sb) {
    dm_rp_layout_make(&s->layout, w, h, kind, left_key, extra_mask, sl, sr, st, sb);
    clear(s);
}

void dm_rp_set_layout(dm_rp_state *s, int kind, int left_key, uint32_t extra_mask) {
    const dm_rp_layout *o = &s->layout;
    dm_rp_layout_make(&s->layout, o->width, o->height, kind, left_key, extra_mask, o->safe_l, o->safe_r, o->safe_t, o->safe_b);
    clear(s);
}

int dm_rp_begin(dm_rp_state *s, int slot, float x, float y) {
    if (slot < 0 || slot >= 16) return DM_RP_INERT;
    if (s->finger_key[slot] > 0 && --s->press_count[s->finger_key[slot]] < 0) s->press_count[s->finger_key[slot]] = 0;
    s->finger_key[slot] = 0;
    s->gesture_active[slot] = s->gesture_fired[slot] = 0;
    int k = dm_rp_hit(&s->layout, x, y);
    if (k > 0) {
        s->finger_key[slot] = k; s->press_count[k]++;
    } else if (k == DM_RP_GESTURE) {
        s->gesture_active[slot] = 1;
        s->touch_x[slot] = x; s->touch_y[slot] = y;
    }
    recompute(s);
    return k;
}

int dm_rp_move(dm_rp_state *s, int slot, float x, float y) {
    if (slot < 0 || slot >= 16 || !s->gesture_active[slot] || s->gesture_fired[slot]) return 0;
    float dx = x - s->touch_x[slot], dy = y - s->touch_y[slot];
    float min = swipe_min(&s->layout);
    if (dx * dx + dy * dy < min * min) return 0;
    int key;
    if (fabsf(dx) > fabsf(dy)) key = dx > 0 ? DM_RP_KEY_RIGHT : DM_RP_KEY_LEFT;
    else key = dy > 0 ? DM_RP_KEY_DOWN : DM_RP_KEY_UP;
    s->gesture_fired[slot] = 1;
    pulse_key(s, key);
    recompute(s);
    return key;
}

int dm_rp_end(dm_rp_state *s, int slot) {
    if (slot < 0 || slot >= 16) return 0;
    uint64_t old = s->buttons;
    if (s->gesture_active[slot]) {
        if (!s->gesture_fired[slot] && s->layout.kind == DM_RP_MENU) pulse_key(s, DM_RP_KEY_A);
        s->gesture_active[slot] = s->gesture_fired[slot] = 0;
    } else {
        int k = s->finger_key[slot];
        if (k > 0 && --s->press_count[k] < 0) s->press_count[k] = 0;
        s->finger_key[slot] = 0;
    }
    recompute(s);
    return s->buttons != old;
}

void dm_rp_cancel(dm_rp_state *s, int slot) {
    if (slot < 0 || slot >= 16) return;
    int k = s->finger_key[slot];
    if (k > 0 && --s->press_count[k] < 0) s->press_count[k] = 0;
    s->finger_key[slot] = 0;
    s->gesture_active[slot] = s->gesture_fired[slot] = 0;
    recompute(s);
}

int dm_rp_tick(dm_rp_state *s) {
    if (s->pulse_frames <= 0) return 0;
    if (--s->pulse_frames > 0) return 0;
    s->pulse = 0;
    recompute(s);
    return 1;
}

void dm_rp_cancel_all(dm_rp_state *s) { clear(s); }
