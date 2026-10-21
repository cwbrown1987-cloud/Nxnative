// dm_touch_layout.c: scene matching, the compiled/default table, the runtime override, generation changes.
#include "../dm_touch_layout.h"
#include "../dm.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

static const char *k_tsv =
    "# test table\n"
    "clap\tB\t\tHigh-Five Fever\n"
    "hurdle\tDown\t\tHop N Slide\n"
    "parasol\tDown\tLeft,Right\tBrolly Good Show\n"
    "beatspell\tB\n"
    "*\tnone\n";

int main(void) {
    char path[1024]; const char *tmp = getenv("TMPDIR"); if (!tmp || !*tmp) tmp = "/tmp";
    snprintf(path, sizeof path, "%s/dm_tl_test_XXXXXX", tmp);
    int fd = mkstemp(path); CHECK(fd >= 0, "mkstemp"); if (fd < 0) return 1;
    CHECK(write(fd, k_tsv, strlen(k_tsv)) == (ssize_t)strlen(k_tsv), "write");
    close(fd);

    CHECK(dm_touch_layout_load(path) == 5, "load rows");
    unsigned g0 = dm_touch_layout_gen();
    CHECK(dm_touch_layout_kind() == DM_TL_MENU, "boot kind %d", dm_touch_layout_kind());
    CHECK(dm_touch_layout_left() == DM_TL_NONE, "boot left %d", dm_touch_layout_left());

    dm_touch_layout_path("rom:/graph/scene/clap/type_00/main.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_GAME, "clap kind %d", dm_touch_layout_kind());
    CHECK(dm_touch_layout_left() == DM_TL_B, "clap left %d", dm_touch_layout_left());
    unsigned g1 = dm_touch_layout_gen(); CHECK(g1 != g0, "gen moved");

    dm_touch_layout_path("rom:/graph/scene/clap/type_00/main.spr");
    CHECK(dm_touch_layout_gen() == g1, "same scene does not move gen");

    dm_touch_layout_path("rom:/graph/scene/common/mesg_frame.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_GAME && dm_touch_layout_left() == DM_TL_B, "common scene ignored");
    dm_touch_layout_path("rom:/graph/scene/master/main.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_MENU && dm_touch_layout_left() == DM_TL_NONE, "master scene is the menu");

    dm_touch_layout_path("rom:/graph/scene/clap/type_00/main.spr");
    dm_touch_layout_path("rom:/graph/result/score.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_RESULT, "result kind %d", dm_touch_layout_kind());
    CHECK(dm_touch_layout_left() == DM_TL_B, "result keeps left");

    dm_touch_layout_path("rom:/graph/menu/tv_adjust/main.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_GAME && dm_touch_layout_left() == DM_TL_NONE, "tv adjust is a game screen");
    dm_touch_layout_path("rom:/graph/menu/title/caution.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_A_RIGHT, "caution is a-right %d", dm_touch_layout_kind());
    CHECK(dm_touch_layout_left() == DM_TL_NONE, "caution left %d", dm_touch_layout_left());
    dm_touch_layout_path("rom:/graph/menu/title/main.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_A_RIGHT, "title is a-right %d", dm_touch_layout_kind());
    dm_touch_layout_path("rom:/graph/menu/start_menu/main.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_START, "start menu is start layout %d", dm_touch_layout_kind());
    dm_touch_layout_path("rom:/graph/menu/main_menu/bg.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_MENU, "main menu is touch %d", dm_touch_layout_kind());
    CHECK(dm_touch_layout_left() == DM_TL_NONE, "main menu left");

    dm_touch_layout_path("rom:/graph/scene/hurdle/type_00/bg.spr");
    CHECK(dm_touch_layout_left() == DM_TL_DOWN, "hurdle left %d", dm_touch_layout_left());

    dm_touch_layout_path("rom:/graph/scene/unknown/type_00/bg.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_GAME, "unknown is a game");
    CHECK(dm_touch_layout_left() == DM_TL_NONE, "unknown default left %d", dm_touch_layout_left());
    char scene[48]; dm_touch_layout_scene(scene, sizeof scene); CHECK(!strcmp(scene, "unknown"), "scene %s", scene);

    dm_touch_layout_path("rom:/graph/scene/parasol/type_00/main.spr");
    CHECK(dm_touch_layout_left() == DM_TL_DOWN, "parasol left");
    CHECK(dm_touch_layout_extra() == ((1u << DM_TL_LEFT) | (1u << DM_TL_RIGHT)), "parasol extra %#x", dm_touch_layout_extra());

    dm_touch_layout_path("rom:/graph/beatspell/main.spr");
    CHECK(dm_touch_layout_kind() == DM_TL_GAME, "beatspell kind");
    CHECK(dm_touch_layout_left() == DM_TL_B, "beatspell left %d", dm_touch_layout_left());

    dm_touch_layout_reset();
    CHECK(dm_touch_layout_kind() == DM_TL_MENU && dm_touch_layout_left() == DM_TL_NONE, "reset");

    unlink(path);
    if (fails) { fprintf(stderr, "%d failure(s)\n", fails); return 1; }
    printf("t_touch_layout: ok\n");
    return 0;
}
