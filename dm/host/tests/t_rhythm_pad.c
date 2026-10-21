// dm_rhythm_pad.c: two-zone and A-only full-screen hit testing, corner priority, menu tap/swipe gestures, pulse decay, multi-touch press counting, layout changes.
#include "../../ios/Sources/dm_rhythm_pad.h"
#include "../dm_input.h"
#include <math.h>
#include <stdio.h>

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

static dm_rp_layout make(int kind, int left, unsigned extra) {
    dm_rp_layout l; dm_rp_layout_make(&l, 932, 430, kind, left, extra, 0, 0, 0, 0); return l;
}
static dm_rp_layout make_safe(int kind, int left, unsigned extra) {
    dm_rp_layout l; dm_rp_layout_make(&l, 932, 430, kind, left, extra, 59, 59, 0, 0); return l;
}

int main(void) {
    dm_rp_layout m = make(DM_RP_MENU, DM_RP_KEY_NONE, 0);
    CHECK(dm_rp_hit(&m, 200, 300) == DM_RP_GESTURE, "menu gesture area %d", dm_rp_hit(&m, 200, 300));
    CHECK(dm_rp_hit(&m, m.b.x, m.b.y) == DM_RP_KEY_B, "menu B");
    CHECK(dm_rp_hit(&m, m.minus.x, m.minus.y) == DM_RP_KEY_MINUS, "menu minus");
    CHECK(dm_rp_hit(&m, m.plus.x, m.plus.y) == DM_RP_KEY_PLUS, "menu plus");
    CHECK(m.b.r == m.plus.r && m.plus.r == m.minus.r, "B and + / - radii %g %g %g", m.b.r, m.plus.r, m.minus.r);
    CHECK(m.plus.x == m.minus.x && m.plus.y < m.minus.y, "+ above - %g,%g %g,%g", m.plus.x, m.plus.y, m.minus.x, m.minus.y);
    float game_w = fminf(m.width, m.height * 16.0f / 9.0f);
    float bar = (m.width - game_w) * 0.5f;
    CHECK(fabsf(m.b.x - bar * 0.5f) < 0.01f, "B is centred in the left bar: %.1f vs %.1f", m.b.x, bar * 0.5f);
    CHECK(fabsf(m.plus.x - (m.width - bar * 0.5f)) < 0.01f, "+ / - are centred in the right bar: %.1f", m.plus.x);
    CHECK(fabsf(m.b.y - (14 + m.b.r)) < 0.01f, "B is at the top inset: %.1f", m.b.y);
    CHECK(m.b.y == m.plus.y, "B and + share the top row: %.1f %.1f", m.b.y, m.plus.y);
    CHECK(m.plus.y < m.minus.y, "+ is above -: %.1f %.1f", m.plus.y, m.minus.y);

    dm_rp_layout ms = make_safe(DM_RP_MENU, DM_RP_KEY_NONE, 0);
    CHECK(fabsf(ms.b.x - m.b.x) < 0.01f, "B ignores the side safe-area inset: %.1f", ms.b.x);
    CHECK(fabsf(ms.plus.x - m.plus.x) < 0.01f, "+ ignores the side safe-area inset: %.1f", ms.plus.x);

    dm_rp_layout full; dm_rp_layout_make(&full, 764, 430, DM_RP_MENU, DM_RP_KEY_NONE, 0, 0, 0, 0, 0);
    CHECK(fabsf(full.b.x - (14 + full.b.r)) < 0.01f, "no side bar: B falls back to the screen edge: %.1f", full.b.x);

    dm_rp_layout g = make(DM_RP_GAME, DM_RP_KEY_DOWN, 0);
    CHECK(dm_rp_hit(&g, 200, 300) == DM_RP_KEY_DOWN, "left half down %d", dm_rp_hit(&g, 200, 300));
    CHECK(dm_rp_hit(&g, 700, 300) == DM_RP_KEY_A, "right half A %d", dm_rp_hit(&g, 700, 300));
    CHECK(dm_rp_hit(&g, g.b.x, g.b.y) == DM_RP_KEY_B, "B wins over the left half");
    CHECK(dm_rp_hit(&g, g.plus.x, g.plus.y) == DM_RP_KEY_PLUS, "+ wins over the right half");

    dm_rp_layout n = make(DM_RP_GAME, DM_RP_KEY_NONE, 0);
    CHECK(dm_rp_hit(&n, 200, 300) == DM_RP_KEY_A, "A-only left half A %d", dm_rp_hit(&n, 200, 300));
    CHECK(dm_rp_hit(&n, 466, 300) == DM_RP_KEY_A, "A-only centre A %d", dm_rp_hit(&n, 466, 300));
    CHECK(dm_rp_hit(&n, n.b.x, n.b.y) == DM_RP_KEY_B, "A-only B wins over full-screen A");
    CHECK(dm_rp_hit(&n, n.plus.x, n.plus.y) == DM_RP_KEY_PLUS, "A-only plus wins over full-screen A");
    dm_rp_state ao; dm_rp_init(&ao, 932, 430, DM_RP_GAME, DM_RP_KEY_NONE, 0, 0, 0, 0, 0);
    CHECK(dm_rp_begin(&ao, 0, 200, 300) == DM_RP_KEY_A, "A-only left press is A");
    CHECK(ao.buttons == DM_BTN_A, "A-only left buttons A %#llx", (unsigned long long)ao.buttons);
    dm_rp_end(&ao, 0);
    CHECK(ao.buttons == 0, "A-only left release");

    dm_rp_layout ar = make(DM_RP_A_RIGHT, DM_RP_KEY_NONE, 0);
    CHECK(dm_rp_hit(&ar, 200, 300) == DM_RP_INERT, "A-right left half inert %d", dm_rp_hit(&ar, 200, 300));
    CHECK(dm_rp_hit(&ar, 700, 300) == DM_RP_KEY_A, "A-right right half A %d", dm_rp_hit(&ar, 700, 300));
    CHECK(dm_rp_hit(&ar, ar.b.x, ar.b.y) == DM_RP_KEY_B, "A-right B wins over A");
    CHECK(dm_rp_hit(&ar, ar.plus.x, ar.plus.y) == DM_RP_KEY_PLUS, "A-right plus wins over right");

    dm_rp_layout an = make(DM_RP_A_RIGHT_NAV, DM_RP_KEY_NONE, 0);
    CHECK(dm_rp_hit(&an, 200, 300) == DM_RP_GESTURE, "A-right-nav left half gestures %d", dm_rp_hit(&an, 200, 300));
    CHECK(dm_rp_hit(&an, 700, 300) == DM_RP_KEY_A, "A-right-nav right half A %d", dm_rp_hit(&an, 700, 300));
    CHECK(dm_rp_hit(&an, an.b.x, an.b.y) == DM_RP_KEY_B, "A-right-nav B wins");

    dm_rp_layout x = make(DM_RP_GAME, DM_RP_KEY_B, (1u << DM_RP_KEY_LEFT) | (1u << DM_RP_KEY_RIGHT));
    CHECK(x.n_extra == 2, "two extra keys %d", x.n_extra);
    CHECK(dm_rp_hit(&x, x.extra[0].x, x.extra[0].y) == DM_RP_KEY_LEFT, "extra left");
    CHECK(dm_rp_hit(&x, x.extra[1].x, x.extra[1].y) == DM_RP_KEY_RIGHT, "extra right");
    CHECK(dm_rp_hit(&x, 200, 200) == DM_RP_KEY_B, "left half still B");

    dm_rp_state menu; dm_rp_init(&menu, 932, 430, DM_RP_MENU, DM_RP_KEY_NONE, 0, 0, 0, 0, 0);
    CHECK(dm_rp_begin(&menu, 0, 200, 300) == DM_RP_GESTURE, "menu gesture");
    CHECK(menu.buttons == 0, "menu gesture no button %#llx", (unsigned long long)menu.buttons);
    CHECK(dm_rp_end(&menu, 0) == 1, "menu tap changes A");
    CHECK(menu.buttons == DM_BTN_A, "menu tap A %#llx", (unsigned long long)menu.buttons);
    int changed = 0; for (int i = 0; i < 32; i++) changed |= dm_rp_tick(&menu);
    CHECK(changed && menu.buttons == 0, "menu tap pulse decays %#llx", (unsigned long long)menu.buttons);

    CHECK(dm_rp_begin(&menu, 0, 200, 300) == DM_RP_GESTURE, "menu swipe start");
    CHECK(dm_rp_move(&menu, 0, 200, 250) == DM_RP_KEY_UP, "menu swipe up %d", dm_rp_move(&menu, 0, 200, 250));
    CHECK(menu.buttons == DM_BTN_UP, "menu swipe up button %#llx", (unsigned long long)menu.buttons);
    CHECK(dm_rp_move(&menu, 0, 200, 200) == 0, "one direction per touch");
    CHECK(dm_rp_end(&menu, 0) == 0, "menu swipe release keeps the pulse");
    CHECK(menu.buttons == DM_BTN_UP, "menu swipe pulse remains %#llx", (unsigned long long)menu.buttons);
    for (int i = 0; i < 32; i++) dm_rp_tick(&menu);
    CHECK(menu.buttons == 0, "menu swipe pulse decays %#llx", (unsigned long long)menu.buttons);

    CHECK(dm_rp_begin(&menu, 0, 200, 300) == DM_RP_GESTURE, "menu swipe right start");
    CHECK(dm_rp_move(&menu, 0, 260, 300) == DM_RP_KEY_RIGHT, "menu swipe right %d", dm_rp_move(&menu, 0, 260, 300));
    CHECK(menu.buttons == DM_BTN_RIGHT, "menu swipe right button %#llx", (unsigned long long)menu.buttons);
    dm_rp_end(&menu, 0);
    for (int i = 0; i < 32; i++) dm_rp_tick(&menu);
    CHECK(menu.buttons == 0, "menu swipe right decays");

    CHECK(dm_rp_begin(&menu, 0, 200, 300) == DM_RP_GESTURE, "menu swipe down start");
    CHECK(dm_rp_move(&menu, 0, 200, 350) == DM_RP_KEY_DOWN, "menu swipe down %d", dm_rp_move(&menu, 0, 200, 350));
    CHECK(menu.buttons == DM_BTN_DOWN, "menu swipe down button %#llx", (unsigned long long)menu.buttons);
    dm_rp_end(&menu, 0);
    for (int i = 0; i < 32; i++) dm_rp_tick(&menu);
    CHECK(menu.buttons == 0, "menu swipe down decays");

    CHECK(dm_rp_begin(&menu, 0, 200, 300) == DM_RP_GESTURE, "menu swipe left start");
    CHECK(dm_rp_move(&menu, 0, 140, 300) == DM_RP_KEY_LEFT, "menu swipe left %d", dm_rp_move(&menu, 0, 140, 300));
    CHECK(menu.buttons == DM_BTN_LEFT, "menu swipe left button %#llx", (unsigned long long)menu.buttons);
    dm_rp_end(&menu, 0);
    for (int i = 0; i < 32; i++) dm_rp_tick(&menu);
    CHECK(menu.buttons == 0, "menu swipe left decays");

    CHECK(dm_rp_begin(&menu, 0, 200, 300) == DM_RP_GESTURE, "menu small move start");
    CHECK(dm_rp_move(&menu, 0, 205, 305) == 0, "small move is not a swipe");
    CHECK(dm_rp_end(&menu, 0) == 1, "small move tap A");
    CHECK(menu.buttons == DM_BTN_A, "small move tap button %#llx", (unsigned long long)menu.buttons);
    for (int i = 0; i < 32; i++) dm_rp_tick(&menu);
    CHECK(menu.buttons == 0, "small move tap decays");

    CHECK(dm_rp_begin(&menu, 0, 200, 300) == DM_RP_GESTURE, "menu cancel start");
    dm_rp_cancel(&menu, 0);
    CHECK(menu.buttons == 0, "cancelled tap is not A %#llx", (unsigned long long)menu.buttons);

    CHECK(dm_rp_begin(&menu, 1, menu.layout.b.x, menu.layout.b.y) == DM_RP_KEY_B, "menu corner B");
    CHECK(menu.buttons == DM_BTN_B, "menu corner B button %#llx", (unsigned long long)menu.buttons);
    dm_rp_end(&menu, 1);
    CHECK(menu.buttons == 0, "menu corner B release");

    dm_rp_state nav; dm_rp_init(&nav, 932, 430, DM_RP_A_RIGHT_NAV, DM_RP_KEY_NONE, 0, 0, 0, 0, 0);
    CHECK(dm_rp_begin(&nav, 0, 200, 300) == DM_RP_GESTURE, "start-menu left gesture");
    CHECK(nav.buttons == 0, "start-menu left no button");
    CHECK(dm_rp_end(&nav, 0) == 0, "start-menu left tap is not A");
    CHECK(nav.buttons == 0, "start-menu left tap no button %#llx", (unsigned long long)nav.buttons);
    CHECK(dm_rp_begin(&nav, 0, 200, 300) == DM_RP_GESTURE, "start-menu swipe start");
    CHECK(dm_rp_move(&nav, 0, 200, 250) == DM_RP_KEY_UP, "start-menu swipe up %d", dm_rp_move(&nav, 0, 200, 250));
    CHECK(nav.buttons == DM_BTN_UP, "start-menu swipe up button");
    dm_rp_end(&nav, 0);
    for (int i = 0; i < 32; i++) dm_rp_tick(&nav);
    CHECK(dm_rp_begin(&nav, 1, 700, 300) == DM_RP_KEY_A, "start-menu right A");
    CHECK(nav.buttons == DM_BTN_A, "start-menu right A button");
    dm_rp_end(&nav, 1);
    CHECK(nav.buttons == 0, "start-menu right A release");

    dm_rp_state ars; dm_rp_init(&ars, 932, 430, DM_RP_A_RIGHT, DM_RP_KEY_NONE, 0, 0, 0, 0, 0);
    CHECK(dm_rp_begin(&ars, 0, 200, 300) == DM_RP_INERT, "A-right left inert");
    CHECK(ars.buttons == 0, "A-right left no button %#llx", (unsigned long long)ars.buttons);
    dm_rp_end(&ars, 0);
    CHECK(dm_rp_begin(&ars, 1, 700, 300) == DM_RP_KEY_A, "A-right right press");
    CHECK(ars.buttons == DM_BTN_A, "A-right buttons A %#llx", (unsigned long long)ars.buttons);
    dm_rp_end(&ars, 1);
    CHECK(ars.buttons == 0, "A-right release");

    dm_rp_state s; dm_rp_init(&s, 932, 430, DM_RP_GAME, DM_RP_KEY_DOWN, 0, 0, 0, 0, 0);
    CHECK(dm_rp_begin(&s, 0, 200, 300) == DM_RP_KEY_DOWN, "press left");
    CHECK(s.buttons == DM_BTN_DOWN, "buttons down %#llx", (unsigned long long)s.buttons);
    CHECK(dm_rp_begin(&s, 1, 700, 300) == DM_RP_KEY_A, "press right");
    CHECK(s.buttons == (DM_BTN_DOWN | DM_BTN_A), "buttons down+A %#llx", (unsigned long long)s.buttons);
    CHECK(dm_rp_end(&s, 0) == 1, "release left changed");
    CHECK(s.buttons == DM_BTN_A, "A remains %#llx", (unsigned long long)s.buttons);
    dm_rp_end(&s, 1);
    CHECK(s.buttons == 0, "all released");

    CHECK(dm_rp_begin(&s, 0, 200, 300) == DM_RP_KEY_DOWN, "press left 1");
    CHECK(dm_rp_begin(&s, 2, 210, 310) == DM_RP_KEY_DOWN, "press left 2");
    dm_rp_end(&s, 0);
    CHECK(s.buttons == DM_BTN_DOWN, "second finger keeps the key %#llx", (unsigned long long)s.buttons);
    dm_rp_end(&s, 2);
    CHECK(s.buttons == 0, "last finger releases");

    CHECK(dm_rp_begin(&s, 3, 700, 300) == DM_RP_KEY_A, "press A");
    dm_rp_set_layout(&s, DM_RP_MENU, DM_RP_KEY_NONE, 0);
    CHECK(s.buttons == 0, "layout change releases all");
    CHECK(dm_rp_hit(&s.layout, 200, 300) == DM_RP_GESTURE, "menu after change");

    dm_rp_cancel_all(&s);
    CHECK(s.buttons == 0, "cancel all");

    if (fails) { fprintf(stderr, "%d failure(s)\n", fails); return 1; }
    printf("t_rhythm_pad: ok\n");
    return 0;
}
