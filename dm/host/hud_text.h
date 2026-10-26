// Text of the Mac overlay panel (front_mac.m): the FPS, shader, render pipeline and load lines, and the overlay mode cycle (hud_text_mac.c).
// Pure formatting, no AppKit and no renderer state, so the tests (tests/t_hud.c) check every format directly.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "sysload.h"

// Key 1 (and F8) cycles off -> all -> FPS only -> off
enum { HUD_OFF = 0, HUD_ALL = 1, HUD_MINIMAL = 2 };
int hud_mode_next(int mode);
const char *hud_mode_name(int mode);   // "all", "FPS only", "off"

// "FPS 60 | game 30": frames put on screen a second ("--" while not known), then the game's own presents a second (left out while not known).
// A missing screen reading is never replaced by the game's rate
void hud_rate_text(char *out, size_t n, int game, int shown);
// The rates, then the game picture's size ("--" while not known) and the internal 3D scene's in brackets when both sides are known:
// "FPS 30 | game 30  1920x1080 (1600x900)"
void hud_frame_text(char *out, size_t n, int game, int shown, int out_w, int out_h, int scene_w, int scene_h);
// "New shaders 3 / total 19592": total < 0 prints "--"
void hud_shader_text(char *out, size_t n, uint64_t fresh, int64_t total);
// "New render pipelines 12 / total 3128": total < 0 prints "--"
void hud_pipeline_text(char *out, size_t n, uint64_t fresh, int64_t total);
// "P 55% 56% 55% 53%  E 43% 29%  T 47%  GPU system 99% (game 70%)": every performance core, every efficiency core, the busiest thread of
// this process (left out while not known), the whole GPU with every app on it ("--" while not known) and this process's own share in brackets (when known)
void hud_load_text(char *out, size_t n, const dm_sysload *load);
