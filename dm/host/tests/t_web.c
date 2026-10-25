// Offline HTML pages (hle_web.c): the argument's entries as the SDK writes them, where the pages are found, the session as Super Mario 3D All-Stars' Sunshine drives its pause menu
// (started hidden, a ready message, Appear, "appear" sent, the page ends at its callback URL), the stand-in without the page or without a web view, and the synchronous form.
// The front end is recorded by the stubs below; no window or guest exists in this test
#define DM_TEST_WEB_FRONT
#include "../hle_web.c"
#include <unistd.h>

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)
static int ev_sig, held, front_ok, opened, shown, closed, hidden_at_open;
static char open_dir[1024], open_path[1024], open_cb[1024], sent[256];
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }
void hle_signal_system_event(void *g) { (void)g; ev_sig = 1; }
void hle_clear_system_event(void *g) { (void)g; ev_sig = 0; }
void dm_input_hold(int on) { held = on; }
int front_web_open(const char *dir, const char *path, const char *callback, int hidden, const dm_web_opts *o) {
    (void)o; if (!front_ok) return -1;
    opened++; hidden_at_open = hidden; snprintf(open_dir, sizeof open_dir, "%s", dir); snprintf(open_path, sizeof open_path, "%s", path); snprintf(open_cb, sizeof open_cb, "%s", callback);
    return 0;
}
void front_web_show(void) { shown++; }
void front_web_send(const char *msg, size_t n) { snprintf(sent, sizeof sent, "%.*s", (int)n, msg); }
void front_web_close(void) { closed++; }

// ShowOfflineHtmlPageArg as the SDK's constructor and setters leave it: the count at +0, the shim kind at +4, entries from +8
static uint8_t g_arg[ARG_SIZE];
static void arg_new(void) { memset(g_arg, 0, sizeof g_arg); *(uint32_t *)(g_arg + 4) = 3; }
static void arg_add(unsigned type, const void *v, unsigned size) {
    size_t o = 8; for (unsigned i = 0; i < *(uint16_t *)g_arg; i++) o += 8 + *(uint16_t *)(g_arg + o + 2);
    *(uint16_t *)(g_arg + o) = (uint16_t)type; *(uint16_t *)(g_arg + o + 2) = (uint16_t)size; memcpy(g_arg + o + 8, v, size); (*(uint16_t *)g_arg)++;
}
static void arg_page(const char *path, int boot_mode) {
    arg_new();
    uint32_t one = 1; arg_add(0x7, &one, 4);   // DocumentKind before the path, as the constructor writes them
    char p[0xc00] = {0}; snprintf(p, sizeof p, "%s", path); arg_add(TLV_DOCUMENT_PATH, p, sizeof p);
    uint32_t three = 3; arg_add(0x17, &three, 4);
    uint32_t bm = (uint32_t)boot_mode; arg_add(TLV_BOOT_MODE, &bm, 4);
}
static void touch(const char *path) { char cmd[2048]; snprintf(cmd, sizeof cmd, "mkdir -p \"$(dirname '%s')\" && : > '%s'", path, path); if (system(cmd)) abort(); }
static uint8_t rv[0x1010];
static uint32_t rv_reason(void) { return (uint32_t)*(uint64_t *)rv; }
static const char *rv_url(void) { return (const char *)rv + 8; }
static uint64_t rv_url_size(void) { return *(uint64_t *)(rv + 0x1008); }
static void *end_later(void *p) { (void)p; usleep(50000); dm_web_ended(3, "http://localhost/continue"); return NULL; }

#define PAUSE "launcher_pause_menu.htdocs/html/en-US/index.html?game=sunshine"
int main(void) {
    char tmp[] = "/tmp/t_web.XXXXXX"; if (!mkdtemp(tmp)) return 1;
    char romfs[256], page[512], dir[1024]; void *ev = NULL; size_t n; char buf[0x40];
    snprintf(romfs, sizeof romfs, "%s/v0/RomFS", tmp); setenv("DM_ROMFS", romfs, 1); unsetenv("DM_HTML");
    snprintf(page, sizeof page, "%s/v0/html/html0/html-document/launcher_pause_menu.htdocs/html/en-US/index.html", tmp); touch(page);

    arg_page(PAUSE, BOOT_INITIALLY_HIDDEN);
    CHECK(web_tlv_u32(g_arg, TLV_BOOT_MODE, 9) == 1 && web_tlv_u32(g_arg, 0x1b, 9) == 9, "argument entries: one present, one absent");
    char path[0xc00]; web_tlv_str(g_arg, TLV_DOCUMENT_PATH, path, sizeof path);
    CHECK(!strcmp(path, PAUSE), "the document path with its query");
    char want[1024]; snprintf(want, sizeof want, "%s/v0/html/html0/html-document", tmp);
    CHECK(web_find(PAUSE, dir, sizeof dir) && !strcmp(dir, want), "pages beside the RomFS folder, in html0/html-document as nx_extract --html writes them");
    CHECK(!web_find("launcher_pause_menu.htdocs/html/ja/index.html", dir, sizeof dir), "a page that is not there");
    CHECK(!web_find("launcher_pause_menu.htdocs/../../../../etc/passwd", dir, sizeof dir) && !web_find("/etc/passwd", dir, sizeof dir), "only paths inside the document");
    setenv("DM_HTML", tmp, 1); snprintf(want, sizeof want, "%s/v0/html/html0/html-document", tmp);
    CHECK(!web_find(PAUSE, dir, sizeof dir), "DM_HTML replaces the default folder");
    snprintf(want, sizeof want, "%s/v0/html", tmp); setenv("DM_HTML", want, 1);
    CHECK(web_find(PAUSE, dir, sizeof dir), "DM_HTML set to the folder");
    unsetenv("DM_HTML");

    // The stand-in: no web view (windowless)
    front_ok = 0;
    CHECK(h_webs_Start(NULL, &ev, g_arg) == RES_OK && ev == g_ev_web && h_webs_Needs(NULL), "stand-in: started");
    CHECK(h_webs_Recv(NULL, &n, buf, sizeof buf) && n == 0 && !buf[0], "stand-in: one empty ready message");
    CHECK(!h_webs_Recv(NULL, &n, buf, sizeof buf), "stand-in: no second message");
    h_webs_Appear(NULL);
    CHECK(ev_sig && !held && !shown, "stand-in: closes as it appears, nothing shown, the input not held");
    memset(rv, 0xcc, sizeof rv); h_webs_Wait(NULL, rv);
    CHECK(rv_reason() == 0 && !rv_url()[0] && rv_url_size() == 0 && !h_webs_Needs(NULL) && !ev_sig, "stand-in: exit reason 0, no last URL, waited for");

    // The pause menu in a web view
    front_ok = 1;
    h_webs_Start(NULL, &ev, g_arg);
    snprintf(want, sizeof want, "%s/v0/html/html0/html-document", tmp);
    CHECK(opened == 1 && hidden_at_open && !strcmp(open_dir, want) && !strcmp(open_path, PAUSE) && !strcmp(open_cb, "http://localhost/"), "opened hidden, with the default callback URL");
    CHECK(!h_webs_Recv(NULL, &n, buf, sizeof buf), "no message before the page sends one");
    dm_web_message("end_sound_load", 14);
    CHECK(h_webs_Recv(NULL, &n, buf, sizeof buf) && n == 14 && !strcmp(buf, "end_sound_load"), "the page's message, its size without the terminating zero");
    h_webs_Appear(NULL);
    CHECK(shown == 1 && held && !ev_sig, "Appear shows the page, which holds the input");
    h_webs_Send(NULL, "appear", 6);
    CHECK(!strcmp(sent, "appear"), "the game's message reaches the page");
    dm_web_message("a long message the game reads only in part", 42);
    CHECK(h_webs_Recv(NULL, &n, buf, 8) && n == 7 && !strcmp(buf, "a long "), "a message longer than the buffer is cut to it");
    dm_web_ended(3, "http://localhost/return_to_launcher");
    CHECK(ev_sig && !held, "the callback URL ends the page: the exit event fires, the input is the game's again");
    dm_web_message("late", 4);
    CHECK(!h_webs_Recv(NULL, &n, buf, sizeof buf), "nothing from a page that ended");
    h_webs_Wait(NULL, rv);
    CHECK(rv_reason() == 3 && !strcmp(rv_url(), "http://localhost/return_to_launcher") && rv_url_size() == 36 && closed == 1 && !h_webs_Needs(NULL), "exit reason 3 and the last URL; the page removed");

    // Started again for the next pause; WaitForExit blocks until the page ends
    h_webs_Start(NULL, &ev, g_arg); dm_web_message("end_sound_load", 14); h_webs_Recv(NULL, &n, buf, sizeof buf); h_webs_Appear(NULL);
    pthread_t th; pthread_create(&th, NULL, end_later, NULL);
    h_webs_Wait(NULL, rv); pthread_join(th, NULL);
    CHECK(rv_reason() == 3 && !strcmp(rv_url(), "http://localhost/continue"), "WaitForExit waits for the page's end");
    h_webs_Start(NULL, &ev, g_arg); h_webs_ReqExit(NULL);
    CHECK(ev_sig, "RequestExit ends the page");
    h_webs_Wait(NULL, rv);
    CHECK(rv_reason() == 2 && !rv_url()[0], "RequestExit: exit reason 2, no last URL");
    h_webs_Start(NULL, &ev, g_arg); dm_web_failed("test");
    CHECK(h_webs_Recv(NULL, &n, buf, sizeof buf) && n == 0, "a page that does not load: the stand-in's ready message");
    h_webs_Appear(NULL);
    CHECK(ev_sig && !held, "and the stand-in closes as it appears");
    h_webs_Wait(NULL, rv);
    h_webs_Start(NULL, &ev, g_arg); int was = closed; h_webs_Fini(NULL);
    CHECK(closed == was + 1 && !h_webs_Needs(NULL), "Finalize closes a page still open");

    // A callback URL of the argument; the synchronous form
    arg_page(PAUSE, BOOT_INITIALLY_HIDDEN); char cb[0x400] = "http://localhost/done"; arg_add(TLV_CALLBACK_URL, cb, sizeof cb);
    h_webs_Start(NULL, &ev, g_arg);
    CHECK(!strcmp(open_cb, "http://localhost/done"), "the argument's callback URL");
    h_webs_ReqExit(NULL); h_webs_Wait(NULL, rv);
    arg_page(PAUSE, BOOT_INITIALLY_HIDDEN); shown = 0;
    pthread_create(&th, NULL, end_later, NULL);
    CHECK(h_web_Offline(rv, g_arg) == RES_OK && rv_reason() == 3 && !hidden_at_open, "ShowOfflineHtmlPage: shown at once and waited for");
    pthread_join(th, NULL);
    CHECK(!held, "and the input is the game's again");
    arg_page("manual/index.html", BOOT_ALL_FOREGROUND);
    CHECK(h_web_Offline(rv, g_arg) == RES_FAIL && !h_webs_Needs(NULL), "ShowOfflineHtmlPage without the page: fails as the cut did");

    char cmd[300]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", tmp); if (system(cmd)) return 1;
    printf("web pages: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
