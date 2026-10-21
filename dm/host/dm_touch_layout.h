// Touch layout for rhythm games (Rhythm Heaven Groove): follows the game's file loads to tell the front end whether it is in a
// menu, the start menu, or a minigame, and which key the left half of the screen should send there. The game has no touch input,
// so the front end turns menu taps into A and menu swipes into D-pad presses; minigames send held keys (an A-only minigame sends A
// from the whole picture).
//
// The table comes from the game profile (dm/games/<id>/touch_layouts.tsv, generated into game_profile.h as
// DM_GAME_TOUCH_LAYOUTS). A runtime file (dm_touch_layout_load) replaces it without rebuilding the app: on iOS the front end
// loads Documents/touch_layouts.tsv, on the Mac DM_TOUCH_LAYOUTS=<path>.
#pragma once
#include <stdint.h>

enum { DM_TL_MENU = 0, DM_TL_GAME = 1, DM_TL_RESULT = 2, DM_TL_A_RIGHT = 3, DM_TL_START = 4 };   // A_RIGHT: boot caution / title, hidden A on the right half; START: start menu, A right plus swipe navigation on the left; result keeps the minigame's keys, so its A still works
enum { DM_TL_NONE = 0, DM_TL_B = 1, DM_TL_LEFT = 2, DM_TL_RIGHT = 3, DM_TL_DOWN = 4, DM_TL_UP = 5 };

// A successful file open (guest thread; hle_fs.c passes the game path such as "rom:/graph/scene/clap/type_00/main.spr")
void dm_touch_layout_path(const char *path);
void dm_touch_layout_reset(void);
// Runtime table override: scene<TAB>left[<TAB>extra][<TAB>note], comments with '#'. Returns the rows loaded, or -1.
int dm_touch_layout_load(const char *path);
int dm_touch_layout_kind(void);
int dm_touch_layout_left(void);            // the key the left half sends (DM_TL_*); NONE in a game means A-only, so the front end uses the whole picture
uint32_t dm_touch_layout_extra(void);      // optional extra keys (bit 1 << DM_TL_*), drawn bottom-left
unsigned dm_touch_layout_gen(void);        // changes on every state change; the front end swaps the layout when it moves
void dm_touch_layout_scene(char *out, int cap);   // current scene dir ("" = none), for logging
