// Scene → touch layout for Rhythm Heaven Groove. See dm_touch_layout.h.
//
// The only signal is the game's own asset loads: a minigame loads graph/scene/<id>/..., the menus load graph/menu/..., and the
// result pages graph/result/.... The boot caution / title screen uses a hidden A on the right half; the start menu keeps that A and
// adds left-half swipe navigation. Minigames send the table's left key on the left half and A on the right; a minigame with no left
// key sends A from the whole picture. The game has no touch input, so the other menus and the hub turn taps into A and swipes into
// D-pad presses. Paths are matched on the guest thread when a file opens (hle_fs.c), and the front end polls the state at 60 Hz,
// so a scene change does not need a frame callback of its own.
#include "dm.h"
#include "dm_touch_layout.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define DM_TL_MAX_ROWS 128

typedef struct { char scene[48]; int left; uint32_t extra; } tl_row;

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_mu;
static tl_row g_tab[DM_TL_MAX_ROWS];
static int g_ntab;
static int g_verbose;

static int g_kind = DM_TL_MENU;
static int g_left = DM_TL_NONE;
static uint32_t g_extra;
static char g_scene[48];
static unsigned g_gen = 1;

// ---- keys ----
static int key_parse(const char *s) {
    if (!s || !*s || !strcasecmp(s, "none")) return DM_TL_NONE;
    if (!strcasecmp(s, "b")) return DM_TL_B;
    if (!strcasecmp(s, "left")) return DM_TL_LEFT;
    if (!strcasecmp(s, "right")) return DM_TL_RIGHT;
    if (!strcasecmp(s, "down")) return DM_TL_DOWN;
    if (!strcasecmp(s, "up")) return DM_TL_UP;
    return -1;
}
static const char *key_name(int k) {
    switch (k) {
        case DM_TL_B: return "B";
        case DM_TL_LEFT: return "Left";
        case DM_TL_RIGHT: return "Right";
        case DM_TL_DOWN: return "Down";
        case DM_TL_UP: return "Up";
        default: return "none";
    }
}
static uint32_t extra_parse(const char *s) {
    uint32_t m = 0;
    if (!s || !*s) return 0;
    char buf[128]; snprintf(buf, sizeof buf, "%s", s);
    for (char *p = buf, *q; p && *p; p = q) {
        q = strchr(p, ','); if (q) *q++ = 0;
        while (*p == ' ') p++;
        char *e = p + strlen(p); while (e > p && e[-1] == ' ') *--e = 0;
        int k = key_parse(p);
        if (k != DM_TL_LEFT && k != DM_TL_RIGHT && k != DM_TL_DOWN && k != DM_TL_UP) return UINT32_MAX;   // extras are directions
        m |= 1u << k;
    }
    return m;
}

static int split_tabs(char *s, char *f[], int max) {
    int n = 1; f[0] = s;
    for (char *p = s; *p; p++) if (*p == '\t') { *p = 0; if (n < max) f[n++] = p + 1; }
    return n;
}

static void log_state_locked(void) {
    if (!g_verbose) return;
    const char *k = g_kind == DM_TL_MENU ? "menu" : g_kind == DM_TL_GAME ? "game" :
                    g_kind == DM_TL_A_RIGHT ? "a-right" : g_kind == DM_TL_START ? "start" : "result";
    if (g_kind == DM_TL_MENU) LOG("touch layout: menu");
    else if (g_kind == DM_TL_A_RIGHT) LOG("touch layout: a-right %s", g_scene[0] ? g_scene : "?");
    else if (g_kind == DM_TL_START) LOG("touch layout: start %s", g_scene[0] ? g_scene : "?");
    else LOG("touch layout: %s %s left=%s", k, g_scene[0] ? g_scene : "?", key_name(g_left));
}

// table and state are changed under g_mu; init_once runs before any other thread can call in
static void table_add(const char *scene, int left, uint32_t extra) {
    if (g_ntab >= DM_TL_MAX_ROWS) { LOG("[RED] touch layout: more than %d rows; ignored %s", DM_TL_MAX_ROWS, scene); return; }
    tl_row *r = &g_tab[g_ntab++];
    snprintf(r->scene, sizeof r->scene, "%s", scene);
    r->left = left; r->extra = extra;
}
static int table_has_default(void) {
    for (int i = 0; i < g_ntab; i++) if (!strcmp(g_tab[i].scene, "*")) return 1;
    return 0;
}
static int table_load_locked(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    static tl_row tmp[DM_TL_MAX_ROWS];   // not on the stack: a front end may call this on a small thread
    int n = 0, lineno = 0;
    char line[1024];
    while (fgets(line, sizeof line, f)) {
        lineno++;
        size_t l = strlen(line); while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        char *p = line; while (*p == ' ' || *p == '\t') p++;
        if (!*p || *p == '#') continue;
        char *fld[4]; int nf = split_tabs(p, fld, 4);
        if (nf < 2) { LOG("[RED] touch layout %s:%d: need scene<TAB>left", path, lineno); continue; }
        int left = key_parse(fld[1]);
        if (left < 0) { LOG("[RED] touch layout %s:%d: unknown key %s", path, lineno, fld[1]); continue; }
        uint32_t extra = extra_parse(nf > 2 ? fld[2] : "");
        if (extra == UINT32_MAX) { LOG("[RED] touch layout %s:%d: unknown extra keys %s", path, lineno, fld[2]); continue; }
        if (n >= DM_TL_MAX_ROWS) { LOG("[RED] touch layout %s: more than %d rows", path, DM_TL_MAX_ROWS); break; }
        snprintf(tmp[n].scene, sizeof tmp[n].scene, "%s", fld[0]);
        tmp[n].left = left; tmp[n].extra = extra; n++;
    }
    fclose(f);
    if (!n) { LOG("[RED] touch layout %s: no rows", path); return -1; }
    int has_default = 0; for (int i = 0; i < n; i++) if (!strcmp(tmp[i].scene, "*")) has_default = 1;
    if (!has_default && n < DM_TL_MAX_ROWS) { snprintf(tmp[n].scene, sizeof tmp[n].scene, "*"); tmp[n].left = DM_TL_NONE; tmp[n].extra = 0; n++; }
    memcpy(g_tab, tmp, sizeof tmp[0] * (size_t)n);
    g_ntab = n;
    g_kind = DM_TL_MENU; g_left = DM_TL_NONE; g_extra = 0; g_scene[0] = 0; g_gen++;
    LOG("touch layout: %d rows from %s", n, path);
    return n;
}
static void table_lookup_locked(const char *scene, int *left, uint32_t *extra) {
    const tl_row *def = NULL;
    for (int i = 0; i < g_ntab; i++) {
        if (!strcmp(g_tab[i].scene, scene)) { *left = g_tab[i].left; *extra = g_tab[i].extra; return; }
        if (!strcmp(g_tab[i].scene, "*")) def = &g_tab[i];
    }
    *left = def ? def->left : DM_TL_NONE; *extra = def ? def->extra : 0;
}

static void init_once(void) {
    pthread_mutex_init(&g_mu, NULL);
    g_verbose = getenv("DM_TOUCH_LAYOUT") != NULL;
    static const char *const k_tab[][3] = DM_GAME_TOUCH_LAYOUTS;
    for (size_t i = 0; i < sizeof k_tab / sizeof k_tab[0]; i++) {
        int left = key_parse(k_tab[i][1]);
        uint32_t extra = extra_parse(k_tab[i][2]);
        if (left < 0 || extra == UINT32_MAX) { LOG("[RED] touch layout: bad compiled row %s/%s", k_tab[i][0], k_tab[i][1]); continue; }
        table_add(k_tab[i][0], left, extra);
    }
    if (!table_has_default()) table_add("*", DM_TL_NONE, 0);
    const char *env = getenv("DM_TOUCH_LAYOUTS");
    if (env && *env && table_load_locked(env) < 0) LOG("[RED] touch layout: could not load %s", env);
}

static void set_locked(int kind, const char *scene, int left, uint32_t extra) {
    if (kind == DM_TL_MENU) { left = DM_TL_NONE; extra = 0; scene = ""; }
    else if (kind == DM_TL_A_RIGHT || kind == DM_TL_START) { left = DM_TL_NONE; extra = 0; }
    if (g_kind == kind && g_left == left && g_extra == extra && !strcmp(g_scene, scene ? scene : "")) return;
    g_kind = kind; g_left = left; g_extra = extra;
    snprintf(g_scene, sizeof g_scene, "%s", scene ? scene : "");
    g_gen++;
    log_state_locked();
}

void dm_touch_layout_path(const char *path) {
    if (!path || !*path) return;
    pthread_once(&g_once, init_once);
    const char *p = strstr(path, "graph/");
    if (!p) return;
    if (g_verbose && (!strncmp(p, "graph/menu/", 11) || !strncmp(p, "graph/scene/", 12)))
        LOG("touch path: %s", p);
    pthread_mutex_lock(&g_mu);
    if (!strncmp(p, "graph/menu/tv_adjust/", 21)) {
        set_locked(DM_TL_GAME, "tv_adjust", DM_TL_NONE, 0);   // first-boot audio-latency test: it wants A, not a touch menu
    } else if (!strncmp(p, "graph/menu/title/", 17)) {
        set_locked(DM_TL_A_RIGHT, "title", DM_TL_NONE, 0);    // boot caution / title: hidden A on the right half, no navigation
    } else if (!strncmp(p, "graph/menu/start_menu/", 22)) {
        set_locked(DM_TL_START, "start_menu", DM_TL_NONE, 0); // start menu: hidden A right, swipe navigation left
    } else if (!strncmp(p, "graph/menu/", 11)) {
        set_locked(DM_TL_MENU, "", DM_TL_NONE, 0);            // other menus: tap A, swipe D-pad
    } else if (!strncmp(p, "graph/result/", 13)) {
        set_locked(DM_TL_RESULT, g_scene, g_left, g_extra);
    } else if (!strncmp(p, "graph/beatspell/", 16)) {
        int left; uint32_t extra; table_lookup_locked("beatspell", &left, &extra);
        set_locked(DM_TL_GAME, "beatspell", left, extra);
    } else if (!strncmp(p, "graph/scene/", 12)) {
        const char *id = p + 12, *e = strchr(id, '/');
        if (!e || e == id || e - id >= (long)sizeof g_scene) { pthread_mutex_unlock(&g_mu); return; }
        char scene[48]; size_t n = (size_t)(e - id); memcpy(scene, id, n); scene[n] = 0;
        // common scenes sit inside minigames; multi_common is shared multiplayer UI. master is the hub (menu): it uses the same
        // tap-A / swipe-D-pad menu layout as the other non-start menus.
        if (!strcmp(scene, "common") || !strcmp(scene, "multi_common")) { pthread_mutex_unlock(&g_mu); return; }
        if (!strcmp(scene, "master")) { set_locked(DM_TL_MENU, "", DM_TL_NONE, 0); pthread_mutex_unlock(&g_mu); return; }
        int left; uint32_t extra; table_lookup_locked(scene, &left, &extra);
        set_locked(DM_TL_GAME, scene, left, extra);
    }
    pthread_mutex_unlock(&g_mu);
}

void dm_touch_layout_reset(void) {
    pthread_once(&g_once, init_once);
    pthread_mutex_lock(&g_mu); set_locked(DM_TL_MENU, "", DM_TL_NONE, 0); pthread_mutex_unlock(&g_mu);
}

int dm_touch_layout_load(const char *path) {
    pthread_once(&g_once, init_once);
    if (!path || !*path) return -1;
    pthread_mutex_lock(&g_mu); int n = table_load_locked(path); pthread_mutex_unlock(&g_mu);
    return n;
}

int dm_touch_layout_kind(void) {
    pthread_once(&g_once, init_once);
    pthread_mutex_lock(&g_mu); int v = g_kind; pthread_mutex_unlock(&g_mu); return v;
}
int dm_touch_layout_left(void) {
    pthread_once(&g_once, init_once);
    pthread_mutex_lock(&g_mu); int v = g_left; pthread_mutex_unlock(&g_mu); return v;
}
uint32_t dm_touch_layout_extra(void) {
    pthread_once(&g_once, init_once);
    pthread_mutex_lock(&g_mu); uint32_t v = g_extra; pthread_mutex_unlock(&g_mu); return v;
}
unsigned dm_touch_layout_gen(void) {
    pthread_once(&g_once, init_once);
    pthread_mutex_lock(&g_mu); unsigned v = g_gen; pthread_mutex_unlock(&g_mu); return v;
}
void dm_touch_layout_scene(char *out, int cap) {
    pthread_once(&g_once, init_once);
    pthread_mutex_lock(&g_mu); if (cap > 0) snprintf(out, (size_t)cap, "%s", g_scene); pthread_mutex_unlock(&g_mu);
}
