// Rhythm pad (Rhythm Heaven Groove): the right half of the screen is A and the left half is the key the current minigame needs
// there; when that key is none (an A-only minigame), the whole picture is A. B sits at the top of the left side bar and + / - at the
// top of the right one, both x-centred in their bar (B same size as the others; + above -). The A_RIGHT layout used by the boot caution / title screen has a hidden A on the right half and
// no key or zone overlays; the start menu uses A_RIGHT_NAV, which adds swipe-to-direction navigation on the left half. The game has
// no touch input, so menus turn a tap into A and a swipe into one D-pad press (dm_rp_move), with no game-touch passthrough. The
// geometry, gestures and press counting are pure C so the Mac tests can cover them (t_rhythm_pad.c); DmRhythmPad.m only draws and
// feeds the touches.
#pragma once
#include <stdint.h>

enum { DM_RP_MENU = 0, DM_RP_GAME = 1, DM_RP_A_RIGHT = 2, DM_RP_A_RIGHT_NAV = 3 };   // A_RIGHT: caution/title; A_RIGHT_NAV: start menu (A right, swipe left half)
enum { DM_RP_INERT = -2, DM_RP_GESTURE = -3 };   // GESTURE = free menu area; caller tracks it and dm_rp_end turns a tap into A

enum {
    DM_RP_KEY_NONE = 0, DM_RP_KEY_B, DM_RP_KEY_A, DM_RP_KEY_PLUS, DM_RP_KEY_MINUS,
    DM_RP_KEY_LEFT, DM_RP_KEY_RIGHT, DM_RP_KEY_DOWN, DM_RP_KEY_UP, DM_RP_KEY_COUNT
};

typedef struct { float x, y, r; int key; } dm_rp_button;
typedef struct {
    float width, height;
    int kind;                 // DM_RP_MENU / DM_RP_GAME / DM_RP_A_RIGHT
    int left_key;             // DM_RP_KEY_* the left half sends (NONE = A-only game: the whole picture sends A; A_RIGHT keeps its own rule)
    dm_rp_button b, plus, minus;
    dm_rp_button extra[4];    // optional extra keys, bottom left
    int n_extra;
    float safe_l, safe_r, safe_t, safe_b;   // kept so a scene change can rebuild the same geometry
} dm_rp_layout;

typedef struct {
    dm_rp_layout layout;
    int finger_key[16];       // key each finger slot holds (0 = none)
    int press_count[DM_RP_KEY_COUNT];
    uint64_t buttons;
    float touch_x[16], touch_y[16];   // gesture start point (menu free areas only)
    unsigned char gesture_active[16], gesture_fired[16];
    uint64_t pulse;           // short A / D-pad press that outlives the touch event
    int pulse_frames;
} dm_rp_state;

void dm_rp_layout_make(dm_rp_layout *l, float width, float height, int kind, int left_key, uint32_t extra_mask,
                       float safe_left, float safe_right, float safe_top, float safe_bottom);
int dm_rp_hit(const dm_rp_layout *l, float x, float y);
uint64_t dm_rp_key_bit(int key);
void dm_rp_init(dm_rp_state *s, float width, float height, int kind, int left_key, uint32_t extra_mask,
                float safe_left, float safe_right, float safe_top, float safe_bottom);
void dm_rp_set_layout(dm_rp_state *s, int kind, int left_key, uint32_t extra_mask);
int dm_rp_begin(dm_rp_state *s, int slot, float x, float y);   // key, or DM_RP_GESTURE / DM_RP_INERT; state->buttons is current
int dm_rp_move(dm_rp_state *s, int slot, float x, float y);    // gesture: one direction pulse per touch; returns its key or 0
int dm_rp_end(dm_rp_state *s, int slot);                       // a gesture tap becomes A (menu layouts only)
void dm_rp_cancel(dm_rp_state *s, int slot);                   // system-cancelled touch: release without turning it into a tap
int dm_rp_tick(dm_rp_state *s);                                // decays pulse presses; returns 1 when the buttons changed
void dm_rp_cancel_all(dm_rp_state *s);
