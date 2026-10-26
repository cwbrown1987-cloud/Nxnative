// Save sync rules with two "devices" (two save directories with their own state) and a plain folder as the cloud: first push, pull, push after a commit,
// a conflict left alone / decided either way (with its backup), a conflict found at push time, a damaged cloud file, an archive that tries to leave its directory.
#import "../savesync_apple.m"
#include <assert.h>

static char g_root[PATH_MAX];
static int g_pick, g_asked, g_notices;
int front_save_sync_choose(const char *title, const char *message) { (void)title; (void)message; g_asked++; return g_pick; }
void front_save_sync_notice(const char *message) { (void)message; g_notices++; }

static void put(const char *dev, const char *rel, const char *text) {
    char p[PATH_MAX]; snprintf(p, sizeof p, "%s/%s/%s", g_root, dev, rel);
    [NSFileManager.defaultManager createDirectoryAtPath:@(p).stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    assert([@(text) writeToFile:@(p) atomically:NO encoding:NSUTF8StringEncoding error:nil]);
}
static NSString *get(const char *dev, const char *rel) {
    char p[PATH_MAX]; snprintf(p, sizeof p, "%s/%s/%s", g_root, dev, rel);
    return [NSString stringWithContentsOfFile:@(p) encoding:NSUTF8StringEncoding error:nil];
}
static const char *dir(const char *dev) { static char p[4][PATH_MAX]; static int k; char *r = p[k++ & 3]; snprintf(r, PATH_MAX, "%s/%s", g_root, dev); return r; }
static void restart(const char *dev) { NSString *d = @(dir(dev)); dispatch_sync(q(), ^{ [g_dirs removeObjectForKey:d]; }); g_asked = g_notices = 0; }   // as if that device's app started again
static void flush(void) { dispatch_sync(q(), ^{}); }
static int backups(const char *dev) {
    char p[PATH_MAX]; snprintf(p, sizeof p, "%s/%s.sync/backup", g_root, dev);
    return (int)[NSFileManager.defaultManager contentsOfDirectoryAtPath:@(p) error:nil].count;
}
static NSString *cloud_digest(void) {
    save_file c; char p[PATH_MAX]; snprintf(p, sizeof p, "%s/cloud/TEST/save.nxsave", g_root);
    return cloud_read(@(p), 5, &c) == CLOUD_OK ? c.digest : nil;
}
static int g_fail;
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); g_fail++; } } while (0)

int main(void) {
    @autoreleasepool {
        snprintf(g_root, sizeof g_root, "%s/t_savesync.XXXXXX", getenv("TMPDIR") ?: "/tmp");
        assert(mkdtemp(g_root));
        char cloud[PATH_MAX]; snprintf(cloud, sizeof cloud, "%s/cloud", g_root); setenv("DM_SAVE_SYNC", cloud, 1); unsetenv("DM_SAVE_SYNC_RESOLVE");

        // 1. Mac has a save, the cloud has none: pushed. A case-collision name keeps its guest name, an empty directory stays
        put("mac", "A.DAT", "mac 1"); put("mac", "sub/B.DAT", "b");
        put("mac", ".dm-case-1", "lower a"); { char p[PATH_MAX]; snprintf(p, sizeof p, "%s/.dm-case-1", dir("mac")); assert(!setxattr(p, GUEST_NAME, "a.dat", 5, 0, 0)); }
        { char p[PATH_MAX]; snprintf(p, sizeof p, "%s/empty", dir("mac")); mkdir(p, 0755); }
        dm_savesync_mount(dir("mac"), "TEST");
        NSString *d1 = cloud_digest();
        CHECK(d1, "first mount pushes the save");

        // 2. The phone has no save yet: pulled, same digest, guest name and empty directory kept, no backup (nothing to lose)
        dm_savesync_mount(dir("phone"), "TEST");
        CHECK([get("phone", "A.DAT") isEqualToString:@"mac 1"] && [get("phone", "sub/B.DAT") isEqualToString:@"b"], "the phone pulls the save");
        { char p[PATH_MAX], g[16] = ""; snprintf(p, sizeof p, "%s/.dm-case-1", dir("phone")); getxattr(p, GUEST_NAME, g, sizeof g, 0, 0); CHECK(!strcmp(g, "a.dat"), "guest name kept: %s", g); }
        { char p[PATH_MAX]; struct stat st; snprintf(p, sizeof p, "%s/empty", dir("phone")); CHECK(!stat(p, &st) && S_ISDIR(st.st_mode), "empty directory kept"); }
        CHECK(!backups("phone"), "nothing to back up on an empty device");
        CHECK([sha256(archive(dir("phone")).body) isEqualToString:d1], "same save, same digest");

        // 3. The phone plays and commits: pushed in the background; the Mac's next start pulls it and keeps its old save as a backup
        put("phone", "A.DAT", "phone 2"); dm_savesync_commit(dir("phone")); flush();
        CHECK(![cloud_digest() isEqualToString:d1], "the commit is pushed");
        restart("mac"); dm_savesync_mount(dir("mac"), "TEST");
        CHECK([get("mac", "A.DAT") isEqualToString:@"phone 2"], "the Mac pulls the phone's progress");
        CHECK(backups("mac") == 1, "the Mac's replaced save is backed up (%d)", backups("mac"));
        CHECK(!g_asked, "no question when only one side changed");

        // 4. Only this device changed (its push never reached the cloud): pushed at the next start
        put("mac", "A.DAT", "mac 3");
        restart("mac"); dm_savesync_mount(dir("mac"), "TEST");
        CHECK([cloud_digest() isEqualToString:sha256(archive(dir("mac")).body)], "an unpushed save is pushed at start");

        // 5. Both changed: "not now" changes nothing on either side, and commits are not pushed this run
        restart("phone"); dm_savesync_mount(dir("phone"), "TEST");   // the phone takes mac 3
        put("phone", "A.DAT", "phone 4"); put("mac", "A.DAT", "mac 4"); dm_savesync_commit(dir("mac")); flush();   // the Mac pushes mac 4 in its run
        NSString *mac4 = cloud_digest();
        restart("phone"); g_pick = 0; dm_savesync_mount(dir("phone"), "TEST");
        CHECK(g_asked == 1, "a conflict asks");
        CHECK([get("phone", "A.DAT") isEqualToString:@"phone 4"] && [cloud_digest() isEqualToString:mac4], "not now: both unchanged");
        dm_savesync_commit(dir("phone")); flush();
        CHECK([cloud_digest() isEqualToString:mac4], "not now: nothing pushed this run");

        // 6. Decided for the cloud: the phone's save is backed up, then replaced
        int b = backups("phone");
        restart("phone"); g_pick = 2; dm_savesync_mount(dir("phone"), "TEST");
        CHECK([get("phone", "A.DAT") isEqualToString:@"mac 4"] && backups("phone") == b + 1, "cloud kept, local backed up");

        // 7. Decided for this device (here by DM_SAVE_SYNC_RESOLVE, without asking): the cloud's save is backed up, then replaced
        put("phone", "A.DAT", "phone 5"); put("mac", "A.DAT", "mac 5"); dm_savesync_commit(dir("mac")); flush();
        setenv("DM_SAVE_SYNC_RESOLVE", "local", 1); b = backups("phone");
        restart("phone"); dm_savesync_mount(dir("phone"), "TEST"); unsetenv("DM_SAVE_SYNC_RESOLVE");
        CHECK(!g_asked && backups("phone") == b + 1, "resolved by the variable, the cloud's save backed up");
        CHECK([cloud_digest() isEqualToString:sha256(archive(dir("phone")).body)], "the phone's save is in the cloud");

        // 8. Another device saves during this run: the next push is refused, the player is told, the cloud keeps the other device's save
        restart("mac"); dm_savesync_mount(dir("mac"), "TEST");   // the Mac takes phone 5
        put("phone", "A.DAT", "phone 6"); dm_savesync_commit(dir("phone")); flush();
        NSString *phone6 = cloud_digest();
        put("mac", "A.DAT", "mac 6"); dm_savesync_commit(dir("mac")); flush();
        CHECK([cloud_digest() isEqualToString:phone6] && g_notices == 1, "a push over another device's save is refused and told");

        // 9. A damaged cloud file: nothing is synced, the save stays, the player is told
        char cf[PATH_MAX]; snprintf(cf, sizeof cf, "%s/TEST/save.nxsave", cloud);
        NSData *good = [NSData dataWithContentsOfFile:@(cf)];
        [[good subdataWithRange:NSMakeRange(0, good.length - 3)] writeToFile:@(cf) atomically:NO];
        restart("mac"); dm_savesync_mount(dir("mac"), "TEST");
        CHECK([get("mac", "A.DAT") isEqualToString:@"mac 6"] && g_notices == 1, "damaged cloud file: nothing changes");
        dm_savesync_commit(dir("mac")); flush();
        CHECK([[NSData dataWithContentsOfFile:@(cf)] length] == good.length - 3, "damaged cloud file: not overwritten this run");

        // 10. An archive whose paths leave the directory is refused whole
        const char *bad[] = {"../x", "/x", "a/../x", "a//x", "a/", ".", ""};
        for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) CHECK(!safe_rel(bad[i]), "unsafe path accepted: %s", bad[i]);
        CHECK(safe_rel("a/.b/c..d"), "safe path refused");
        NSMutableData *evil = [NSMutableData data]; uint8_t t = 'f'; uint64_t sz = 1;
        [evil appendBytes:&t length:1]; put16(evil, 4); [evil appendBytes:"../x" length:4]; put16(evil, 0); [evil appendBytes:&sz length:8]; [evil appendBytes:"x" length:1];
        char to[PATH_MAX], esc[PATH_MAX]; snprintf(to, sizeof to, "%s/evil", g_root); snprintf(esc, sizeof esc, "%s/x", g_root);
        CHECK(unpack(evil, to) && access(esc, F_OK), "an escaping archive is refused");

        [NSFileManager.defaultManager removeItemAtPath:@(g_root) error:nil];
    }
    if (g_fail) { fprintf(stderr, "t_savesync: %d failed\n", g_fail); return 1; }
    printf("t_savesync: ok\n");
    return 0;
}
