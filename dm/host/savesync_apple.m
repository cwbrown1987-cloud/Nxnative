// Save sync through a cloud folder (DM_SAVE_SYNC=<folder>, normally one in iCloud Drive): the Mac app and the iPhone app take turns on one save.
// Each transactional save directory (hle_fs.c: $DM_SAVE, and <DM_SAVE>_device when the game has a device save) is kept in the folder as one archive file,
// <folder>/<program ID>/save.nxsave (save_device.nxsave). One file, not a tree: iCloud moves a file whole, while a tree arrives file by file and another device could read half of a save.
// The archive is a short text header (format, the SHA-256 of the body, the device that wrote it, when) and the zlib-compressed body: every directory and file of the save,
// sorted by path, with its guest name (hle_fs.c's org.d2rmobile.guest-name, set on case-collision names) and its bytes; no times, so one save always gives the same digest.
// Each device keeps in <save directory>.sync/base the digest of the version it last synced (pulled or pushed). At the first mount of a save in a run (before hle_fs.c clones its work directory):
//   cloud missing                        → push this device's save (when it has one)
//   cloud = local                        → nothing to do
//   local = base, or local empty         → only the cloud changed: pull it
//   cloud = base                         → only this device changed (a push that did not reach the cloud): push
//   otherwise                            → both changed: conflict, the player chooses (DM_SAVE_SYNC_RESOLVE=local|cloud chooses without asking); "not now" leaves both and syncs nothing this run
// After every commit the committed save is pushed in the background, unless the cloud has moved away from base (another device saved meanwhile): then nothing more is pushed this run
// and the next start asks. Whatever a sync overwrites on this device (a pull) or of another device's (a conflict decided for this device, a version iCloud set aside) is first kept in
// <save directory>.sync/backup (the last 10; dm/tools/nxsave.py unpacks one). The cloud unreachable or its file unreadable: nothing is synced this run and the save stays on this device.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

#define SLOG(...) do { fprintf(stderr, "[dm] save sync: " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define GUEST_NAME "org.d2rmobile.guest-name"
#define KEEP_BACKUPS 10

// Front end (front.h; front_ios.m, front_mac.m, with do-nothing defaults in hle_fs.c): ask which save to keep (1 this device, 2 the cloud, 0 neither this run), tell the player something went wrong
int front_save_sync_choose(const char *title, const char *message);
void front_save_sync_notice(const char *message);

@interface DmSyncDir : NSObject
@property NSString *dir, *cloud, *state, *base;
@property BOOL off;   // nothing more is synced this run
@end
@implementation DmSyncDir
@end

static NSMutableDictionary<NSString *, DmSyncDir *> *g_dirs;   // save directory → its sync; touched only on q()
static dispatch_queue_t q(void) {
    static dispatch_queue_t sq; static dispatch_once_t once;
    dispatch_once(&once, ^{ sq = dispatch_queue_create("dm.savesync", DISPATCH_QUEUE_SERIAL); g_dirs = [NSMutableDictionary new]; });
    return sq;
}

// ---- archive body ----
typedef struct { NSMutableData *body; int entries, err; time_t newest; } walk_t;
static void put16(NSMutableData *d, size_t v) { uint16_t x = (uint16_t)v; [d appendBytes:&x length:2]; }
static int by_name(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static void walk(const char *root, const char *rel, walk_t *w) {
    char p[PATH_MAX]; snprintf(p, sizeof p, "%s%s%s", root, *rel ? "/" : "", rel);
    DIR *d = opendir(p);
    if (!d) { if (*rel || errno != ENOENT) w->err = errno ? errno : EIO; return; }   // a save directory not made yet is an empty save
    char **v = NULL; size_t n = 0, cap = 0; struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (n == cap) v = realloc(v, (cap = cap ? cap * 2 : 16) * sizeof *v);
        v[n++] = strdup(e->d_name);
    }
    closedir(d);
    if (n) qsort(v, n, sizeof *v, by_name);
    for (size_t i = 0; i < n; i++) {
        char r[PATH_MAX], f[PATH_MAX], g[1024]; struct stat st;
        snprintf(r, sizeof r, "%s%s%s", rel, *rel ? "/" : "", v[i]); snprintf(f, sizeof f, "%s/%s", root, r);
        free(v[i]);
        if (w->err) continue;
        if (lstat(f, &st)) { w->err = errno; continue; }
        if (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)) continue;
        ssize_t gl = getxattr(f, GUEST_NAME, g, sizeof g, 0, XATTR_NOFOLLOW); if (gl < 0) gl = 0;
        uint8_t t = S_ISDIR(st.st_mode) ? 'd' : 'f';
        [w->body appendBytes:&t length:1]; put16(w->body, strlen(r)); [w->body appendBytes:r length:strlen(r)]; put16(w->body, (size_t)gl); [w->body appendBytes:g length:(size_t)gl];
        w->entries++;
        if (t == 'd') { walk(root, r, w); continue; }
        NSData *data = [NSData dataWithContentsOfFile:@(f) options:0 error:nil];
        if (!data) { w->err = EIO; continue; }
        uint64_t sz = data.length; [w->body appendBytes:&sz length:8]; [w->body appendData:data];
        if (st.st_mtime > w->newest) w->newest = st.st_mtime;
    }
    free(v);
}
static walk_t archive(const char *dir) { walk_t w = {.body = [NSMutableData data]}; walk(dir, "", &w); return w; }

static int safe_rel(const char *r) {   // the cloud file is outside this device's control: no absolute path, no "." / ".." / empty component
    for (const char *c = r;; ) {
        size_t n = strcspn(c, "/");
        if (!n || (n == 1 && c[0] == '.') || (n == 2 && c[0] == '.' && c[1] == '.')) return 0;
        if (!c[n]) return 1;
        c += n + 1;
    }
}
static int unpack(NSData *body, const char *to) {   // into the new directory <to>; 0 = done
    if (mkdir(to, 0755)) return -1;
    const uint8_t *p = body.bytes, *end = p + body.length;
    while (p < end) {
        uint16_t pl, gl; uint64_t sz = 0; char r[PATH_MAX], g[1024], f[PATH_MAX];
        if (end - p < 3) return -1;
        uint8_t t = *p++; memcpy(&pl, p, 2); p += 2;
        if ((t != 'd' && t != 'f') || pl >= sizeof r || end - p < pl + 2) return -1;
        memcpy(r, p, pl); r[pl] = 0; p += pl; memcpy(&gl, p, 2); p += 2;
        if (strlen(r) != pl || !safe_rel(r) || gl >= sizeof g || end - p < gl) return -1;
        memcpy(g, p, gl); p += gl;
        if ((size_t)snprintf(f, sizeof f, "%s/%s", to, r) >= sizeof f) return -1;
        if (t == 'd') { if (mkdir(f, 0755) && errno != EEXIST) return -1; }
        else {
            if (end - p < 8) return -1;
            memcpy(&sz, p, 8); p += 8;
            if ((uint64_t)(end - p) < sz) return -1;
            int fd = open(f, O_WRONLY | O_CREAT | O_EXCL, 0644); if (fd < 0) return -1;
            for (uint64_t o = 0; o < sz; ) { ssize_t k = write(fd, p + o, sz - o); if (k <= 0) { close(fd); return -1; } o += (uint64_t)k; }
            if (close(fd)) return -1;
            p += sz;
        }
        if (gl && setxattr(f, GUEST_NAME, g, gl, 0, XATTR_NOFOLLOW)) return -1;
    }
    return 0;
}

static NSString *sha256(NSData *d) {
    uint8_t h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString string]; for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", h[i]];
    return s;
}

// ---- the .nxsave file ----
static NSString *device_name(void) {
    NSString *n = nil;
#if TARGET_OS_IPHONE
    n = NSProcessInfo.processInfo.hostName;   // UIDevice is main-thread only; this name is informational
#else
    n = NSHost.currentHost.localizedName;
#endif
    return [[n ?: @"unknown" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
}
static NSData *pack_file(NSData *body, NSString *digest) {
    NSData *z = body.length ? [body compressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil] : [NSData data];
    if (!z) return nil;
    NSMutableData *f = [[[NSString stringWithFormat:@"NXSAVE 1\ndigest %@\ndevice %@\ntime %ld\n\n", digest, device_name(), (long)time(NULL)] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [f appendData:z];
    return f;
}
typedef struct { NSData *raw, *body; NSString *digest, *device; long time; } save_file;
static int parse_file(NSData *raw, save_file *s) {   // 0 = a complete archive whose body matches its digest
    *s = (save_file){.raw = raw};
    NSRange e = [raw rangeOfData:[NSData dataWithBytes:"\n\n" length:2] options:0 range:NSMakeRange(0, MIN(raw.length, (NSUInteger)4096))];
    if (e.location == NSNotFound) return -1;
    NSString *head = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, e.location)] encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\n"];
    if (!lines.count || ![lines[0] isEqualToString:@"NXSAVE 1"]) return -1;
    for (NSString *l in lines) {
        if ([l hasPrefix:@"digest "]) s->digest = [l substringFromIndex:7];
        else if ([l hasPrefix:@"device "]) s->device = [l substringFromIndex:7];
        else if ([l hasPrefix:@"time "]) s->time = [l substringFromIndex:5].longLongValue;
    }
    NSData *z = [raw subdataWithRange:NSMakeRange(NSMaxRange(e), raw.length - NSMaxRange(e))];
    s->body = z.length ? [z decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil] : [NSData data];
    return s->digest && s->body && [sha256(s->body) isEqualToString:s->digest] ? 0 : -1;
}

// ---- the cloud folder (coordinated: iCloud Drive may still be downloading or uploading the file; given up after a timeout) ----
enum { CLOUD_NONE, CLOUD_OK, CLOUD_BAD, CLOUD_UNREACHABLE };
static int coordinate(NSURL *u, BOOL write, double timeout, BOOL (^work)(NSURL *, NSError **), NSError **err) {
    NSFileCoordinator *c = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL ok = NO; __block NSError *e = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *ce = nil; __block NSError *we = nil;
        void (^acc)(NSURL *) = ^(NSURL *nu) { NSError *x = nil; ok = work(nu, &x); we = x; };
        if (write) [c coordinateWritingItemAtURL:u options:NSFileCoordinatorWritingForReplacing error:&ce byAccessor:acc];
        else [c coordinateReadingItemAtURL:u options:0 error:&ce byAccessor:acc];
        e = ce ?: we;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)))) {
        [c cancel];
        if (err) *err = [NSError errorWithDomain:NSPOSIXErrorDomain code:ETIMEDOUT userInfo:@{NSLocalizedDescriptionKey: @"timed out"}];
        return 0;
    }
    if (err) *err = e;
    return ok;
}
static int missing(NSError *e) {
    return ([e.domain isEqualToString:NSCocoaErrorDomain] && (e.code == NSFileReadNoSuchFileError || e.code == NSFileNoSuchFileError))
        || ([e.domain isEqualToString:NSPOSIXErrorDomain] && e.code == ENOENT);
}
static int cloud_read(NSString *path, double timeout, save_file *out) {
    NSURL *u = [NSURL fileURLWithPath:path];
    [NSFileManager.defaultManager startDownloadingUbiquitousItemAtURL:u error:nil];   // only for iCloud Drive; elsewhere it fails, harmlessly
    __block NSData *raw = nil; NSError *e = nil;
    int ok = coordinate(u, NO, timeout, ^BOOL(NSURL *nu, NSError **we) { raw = [NSData dataWithContentsOfURL:nu options:0 error:we]; return raw != nil; }, &e);
    if (!ok) {
        if (missing(e)) return CLOUD_NONE;
        SLOG("[RED] cannot read %s: %s", path.UTF8String, e.localizedDescription.UTF8String);
        return CLOUD_UNREACHABLE;
    }
    if (parse_file(raw, out)) { SLOG("[RED] %s is not a complete save archive (%lu bytes)", path.UTF8String, (unsigned long)raw.length); return CLOUD_BAD; }
    return CLOUD_OK;
}
static int cloud_write(NSString *path, NSData *f) {
    NSURL *u = [NSURL fileURLWithPath:path]; NSError *e = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (coordinate(u, YES, 30, ^BOOL(NSURL *nu, NSError **we) { return [f writeToURL:nu options:NSDataWritingAtomic error:we]; }, &e)) return 1;
    SLOG("[RED] cannot write %s: %s", path.UTF8String, e.localizedDescription.UTF8String);
    return 0;
}

// ---- this device's state ----
static void set_base(DmSyncDir *s, NSString *digest) {
    if ([s.base isEqualToString:digest]) return;
    s.base = digest;
    if (![digest writeToFile:[s.state stringByAppendingPathComponent:@"base"] atomically:YES encoding:NSUTF8StringEncoding error:nil])
        SLOG("[RED] cannot record the synced version in %s", s.state.UTF8String);
}
static void backup(DmSyncDir *s, NSData *file, const char *what) {
    static int seq;
    NSString *dir = [s.state stringByAppendingPathComponent:@"backup"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    char stamp[32]; time_t t = time(NULL); strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", localtime(&t));
    NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%s-%d-%s.nxsave", stamp, ++seq, what]];
    if (!file || ![file writeToFile:p atomically:YES]) { SLOG("[RED] cannot keep a backup at %s", p.UTF8String); return; }
    SLOG("kept %s as a backup: %s", what, p.UTF8String);
    NSArray<NSString *> *all = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i + KEEP_BACKUPS < all.count; i++) [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:all[i]] error:nil];
}
static int push(DmSyncDir *s, NSData *body, NSString *digest) {
    NSData *f = pack_file(body, digest);
    if (!f || !cloud_write(s.cloud, f)) return 0;
    set_base(s, digest);
    SLOG("pushed %s to %s (%lu bytes, %.12s)", s.dir.UTF8String, s.cloud.UTF8String, (unsigned long)f.length, digest.UTF8String);
    return 1;
}
static int pull(DmSyncDir *s, save_file *c) {   // the cloud's save replaces the directory in one swap; on any failure the directory is unchanged
    const char *dir = s.dir.fileSystemRepresentation;
    char tmp[PATH_MAX]; snprintf(tmp, sizeof tmp, "%s.pull", dir);
    [NSFileManager.defaultManager removeItemAtPath:@(tmp) error:nil];
    mkdir(dir, 0755);
    if (unpack(c->body, tmp) || renamex_np(tmp, dir, RENAME_SWAP)) {
        SLOG("[RED] cannot unpack the cloud save into %s (errno %d); this device's save is unchanged", dir, errno);
        [NSFileManager.defaultManager removeItemAtPath:@(tmp) error:nil];
        return 0;
    }
    [NSFileManager.defaultManager removeItemAtPath:@(tmp) error:nil];   // the replaced save, swapped out (a backup was kept)
    set_base(s, c->digest);
    SLOG("pulled %s from %s (saved %ld on %s)", dir, s.cloud.UTF8String, c->time, c->device.UTF8String);
    return 1;
}
static NSString *when(long t) {
    NSDateFormatter *f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle; f.timeStyle = NSDateFormatterShortStyle;
    return t ? [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]] : @"unknown";
}

static void reconcile(DmSyncDir *s) {
    walk_t w = archive(s.dir.fileSystemRepresentation);
    if (w.err) { s.off = YES; SLOG("[RED] cannot read %s (errno %d): not synced this run", s.dir.UTF8String, w.err); return; }
    NSString *L = sha256(w.body); BOOL lempty = !w.entries;
    save_file c; int cs = cloud_read(s.cloud, 30, &c);
    if (cs == CLOUD_UNREACHABLE || cs == CLOUD_BAD) {
        s.off = YES;
        front_save_sync_notice(cs == CLOUD_BAD ? "The save in the sync folder is damaged or incomplete, so nothing is synced this time. Your save stays on this device."
                                               : "The sync folder could not be reached, so nothing is synced this time. Your save stays on this device.");
        return;
    }
    // Versions iCloud set aside when two devices wrote the file at once: one of them may be this device's last push, which lost to the other device's
    NSURL *u = [NSURL fileURLWithPath:s.cloud];
    NSArray<NSFileVersion *> *versions = cs == CLOUD_OK ? [NSFileVersion unresolvedConflictVersionsOfItemAtURL:u] ?: @[] : @[];
    BOOL raced = NO;
    for (NSFileVersion *v in versions) {
        save_file o; NSData *raw = [NSData dataWithContentsOfURL:v.URL];
        if (!raw || parse_file(raw, &o) || [o.digest isEqualToString:c.digest]) continue;
        if ([o.digest isEqualToString:L]) raced = YES;
        else backup(s, raw, "other-device");
    }
    enum { NOTHING, PUSH, PULL, ASK } act;
    if (cs == CLOUD_NONE) act = lempty ? NOTHING : PUSH;
    else if ([c.digest isEqualToString:L]) act = NOTHING;
    else if (raced) act = ASK;
    else if (lempty || [L isEqualToString:s.base]) act = PULL;
    else if ([c.digest isEqualToString:s.base]) act = PUSH;
    else act = ASK;
    if (act == ASK) {
        const char *env = getenv("DM_SAVE_SYNC_RESOLVE"); int pick;
        if (env && !strcmp(env, "local")) pick = 1;
        else if (env && !strcmp(env, "cloud")) pick = 2;
        else {
            NSString *m = [NSString stringWithFormat:@"This device and the sync folder each have progress the other does not.\n\nThis device: last saved %@\nSync folder: saved %@ on %@\n\nThe save you do not keep is put in %@.",
                           when(w.newest), when(c.time), c.device ?: @"another device", [s.state stringByAppendingPathComponent:@"backup"]];
            pick = front_save_sync_choose("Which save do you want to keep?", m.UTF8String);
        }
        SLOG("both this device and the cloud changed since the last sync (local %.12s, cloud %.12s from %s, base %.12s): %s", L.UTF8String, c.digest.UTF8String, c.device.UTF8String,
             s.base.UTF8String ?: "none", pick == 1 ? "keeping this device's" : pick == 2 ? "keeping the cloud's" : "[RED] keeping both, nothing is synced this run");
        if (pick != 1 && pick != 2) { s.off = YES; return; }
        if (pick == 1) backup(s, c.raw, "cloud");
        act = pick == 1 ? PUSH : PULL;
    }
    if (act == PULL && !lempty) backup(s, pack_file(w.body, L), "local");
    if (act == PUSH && !push(s, w.body, L)) return;   // tried again at the next commit, and at the next start
    if (act == PULL && !pull(s, &c)) { s.off = YES; return; }
    if (act == NOTHING) { if (cs == CLOUD_OK) set_base(s, L); SLOG("%s is in sync with %s", s.dir.UTF8String, s.cloud.UTF8String); }
    if (versions.count) {
        for (NSFileVersion *v in versions) v.resolved = YES;
        coordinate(u, YES, 30, ^BOOL(NSURL *nu, NSError **we) { return [NSFileVersion removeOtherVersionsOfItemAtURL:nu error:we]; }, NULL);
    }
}

// hle_fs.c, the first mount of a transactional save in this run, before its work directory is cloned. Waits for the cloud (and for the player, on a conflict)
void dm_savesync_mount(const char *dir, const char *title) {
    const char *root = getenv("DM_SAVE_SYNC");
    if (!root || !*root) return;
    @autoreleasepool {
        NSString *d = @(dir);
        dispatch_sync(q(), ^{
            if (g_dirs[d]) return;
            DmSyncDir *s = [DmSyncDir new]; g_dirs[d] = s;
            s.dir = d; s.state = [d stringByAppendingString:@".sync"];
            NSString *name = [d hasSuffix:@"_device"] ? @"save_device.nxsave" : @"save.nxsave";
            s.cloud = [[[@(root) stringByExpandingTildeInPath] stringByAppendingPathComponent:@(title)] stringByAppendingPathComponent:name];
            [NSFileManager.defaultManager createDirectoryAtPath:s.state withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *b = [NSString stringWithContentsOfFile:[s.state stringByAppendingPathComponent:@"base"] encoding:NSUTF8StringEncoding error:nil];
            s.base = [b stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length ? [b stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
            reconcile(s);
        });
    }
}

// hle_fs.c, after a commit swapped the save in (under its locks, so the directory is read whole): the push itself runs on the sync queue
void dm_savesync_commit(const char *dir) {
    const char *root = getenv("DM_SAVE_SYNC");
    if (!root || !*root) return;
    @autoreleasepool {
        walk_t w = archive(dir);
        if (w.err) { SLOG("[RED] cannot read %s after its commit (errno %d): not pushed", dir, w.err); return; }
        NSString *d = @(dir); NSData *body = w.body;
#if TARGET_OS_IPHONE
        __block UIBackgroundTaskIdentifier bt = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"save sync" expirationHandler:^{ [UIApplication.sharedApplication endBackgroundTask:bt]; bt = UIBackgroundTaskInvalid; }];
#endif
        dispatch_async(q(), ^{
            DmSyncDir *s = g_dirs[d];
            if (s && !s.off) {
                NSString *digest = sha256(body); save_file c; int cs = cloud_read(s.cloud, 15, &c);
                if (cs == CLOUD_OK && [c.digest isEqualToString:digest]) { set_base(s, digest); SLOG("%s unchanged by its commit: already in the cloud", d.UTF8String); }
                else if (cs == CLOUD_NONE || (cs == CLOUD_OK && [c.digest isEqualToString:s.base])) push(s, body, digest);
                else if (cs == CLOUD_UNREACHABLE) SLOG("[RED] %s not pushed: the cloud cannot be reached (tried again at the next save)", d.UTF8String);
                else {
                    s.off = YES;
                    SLOG("[RED] %s not pushed: the cloud's save changed since this run started (%.12s from %s); nothing more is pushed this run, the next start asks which to keep", d.UTF8String,
                         cs == CLOUD_OK ? c.digest.UTF8String : "unreadable", cs == CLOUD_OK ? c.device.UTF8String : "?");
                    front_save_sync_notice("Another device saved to the sync folder while you were playing. Your progress is saved on this device; the next time the game starts you can choose which save to keep.");
                }
            }
#if TARGET_OS_IPHONE
            if (bt != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:bt]; bt = UIBackgroundTaskInvalid; }
#endif
        });
    }
}
