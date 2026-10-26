// Exercise the exact mount-list Commit ABI with synthetic files, no guest SDK.
#include <sys/types.h>
static ssize_t fake_pwrite(int fd, const void *buf, size_t n, off_t off);
#define pwrite fake_pwrite
#include "../hle_fs.c"
#undef pwrite
#include <mach-o/getsect.h>
ssize_t pwrite(int, const void *, size_t, off_t);

struct dm_flags g_flag; uint64_t g_t0_ns;
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
void dm_prof_add(int id, uint64_t ns, uint64_t b) { (void)id; (void)ns; (void)b; }
void dm_guest_write_prepare(void *a, size_t n) { (void)a; (void)n; }
extern int g_nfail;
static int fail_write, write_calls;
static ssize_t fake_pwrite(int fd, const void *buf, size_t n, off_t off) {
    if (fail_write) { if (++write_calls > 10) { fputs("FAIL: retrying a zero-byte write\n", stderr); exit(1); } return 0; }
    return pwrite(fd, buf, n, off);
}
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
static void put(const char *path, const char *s) {
    FILE *f = fopen(path, "w"); if (!f) { perror(path); exit(2); } fputs(s, f); fclose(f);
}
static int same(const char *path, const char *s) {
    char b[64] = {0}; FILE *f = fopen(path, "r"); if (!f) return 0;
    size_t n = fread(b, 1, sizeof b - 1, f); fclose(f);
    return n == strlen(s) && !memcmp(b, s, n);
}
static Result write_save(const char *path, const char *s) {
    uint64_t h; Result r = h_fs_OpenFile(&h, path, MODE_WRITE); if (r) return r;
    r = h_fs_SetFileSize(h, (int64_t)strlen(s));
    if (!r) r = h_fs_WriteFile(h, 0, s, strlen(s), NULL);
    h_fs_CloseFile(h); return r;
}
static int read_save(const char *path, char *out, size_t n) {
    uint64_t h; size_t got = 0; if (h_fs_OpenFile(&h, path, MODE_READ)) return 0;
    Result r = h_fs_ReadFile(&got, h, 0, out, n - 1); h_fs_CloseFile(h); out[got] = 0; return !r;
}
typedef struct { uint64_t h; Result write_result, size_result; } failed_io;
static void *fail_save_io(void *arg) {
    failed_io *io = arg;
    io->write_result = h_fs_WriteFile(io->h, 0, "bad", 3, NULL);
    io->size_result = h_fs_SetFileSize(io->h, -1);
    return NULL;
}
extern const struct mach_header_64 _mh_execute_header;
static Result (*list_hook(void))(const char *const *, int) {
    unsigned long bytes = 0;
    const hle_force_ent *e = (const hle_force_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &bytes);
    for (size_t i = 0; e && i < bytes / sizeof *e; i++)
        if (!strcmp(e[i].name, "_ZN2nn2fs6CommitEPKPKci")) return e[i].fn;
    return NULL;
}
int main(void) {
    unsetenv("DM_TEST_FS_FAIL"); unsetenv("DM_TEST_FS_FAILAT");
    Result (*commit)(const char *const *, int) = list_hook();
    CHECK(commit != NULL, "exact mount-list Commit symbol is registered");
    if (!commit) return 1;
    const char *one[] = {"save"};
    char root[1024], save[1100], other[1100], path[1200], bpath[1200];
    snprintf(root, sizeof root, "%s/list-commit.XXXXXX", getenv("TMPDIR") ?: "/private/tmp");
    if (!mkdtemp(root)) return 2;
    snprintf(save, sizeof save, "%s/save", root); mkdir(save, 0755);
    snprintf(path, sizeof path, "%s/a", save); put(path, "old"); setenv("DM_SAVE", save, 1);
    CHECK(h_fs_MountSave("save", NULL) == RES_OK, "mount transactional output");
    CHECK(write_save("save:/a", "new") == RES_OK && same(path, "old"), "writes remain uncommitted");
    uint64_t n = dm_fs_commit_count();
    CHECK(commit(one, 1) == RES_OK && same(path, "new"), "one-element list commits actual file bytes");
    CHECK(dm_fs_commit_count() == n + 1, "one transaction");
    g_nmnt = 0; // Simulate a fresh mount after process restart.
    CHECK(h_fs_MountSave("save", NULL) == RES_OK, "remount committed data");
    char got[64]; CHECK(read_save("save:/a", got, sizeof got) && !strcmp(got, "new"), "committed bytes survive remount");
    fail_write = 1; write_calls = 0;
    CHECK(write_save("save:/a", "bad") == RES_FAIL, "inject a failed write"); fail_write = 0;
    n = dm_fs_commit_count(); int nf = g_nfail;
    CHECK(commit(one, 1) != RES_OK && same(path, "new"), "poisoned list commit fails without publishing bad bytes");
    CHECK(dm_fs_commit_count() == n && g_nfail == nf + 1, "refused transaction not counted; front end notified");
    CHECK(write_save("save:/a", "good") == RES_OK && commit(one, 1) == RES_OK && same(path, "good"), "next clean transaction succeeds");
    CHECK(write_save("save:/a", "pending0") == RES_OK, "stage a write before the alias is mounted");
    CHECK(h_fs_MountSave("alias", NULL) == RES_OK, "mount an alias of the same host transaction");
    CHECK(read_save("alias:/a", got, sizeof got) && !strcmp(got, "pending0") && same(path, "good"), "the alias shares the pending write instead of recloning over it");
    const char *aliases[] = {"save", "alias", "save"};
    CHECK(write_save("alias:/a", "alias-new") == RES_OK, "write through alias"); n = dm_fs_commit_count();
    CHECK(commit(aliases, 3) == RES_OK && same(path, "alias-new"), "aliases sharing one backing transaction commit together");
    CHECK(dm_fs_commit_count() == n + 1, "duplicates do not commit twice");
    fail_write = 1; write_calls = 0;
    CHECK(write_save("alias:/a", "alias-bad") == RES_FAIL, "failed write through an alias poisons its backing transaction");
    fail_write = 0;
    CHECK(h_fs_Commit("save") != RES_OK && same(path, "alias-new"), "committing through the primary name observes the alias failure");
    CHECK(write_save("save:/a", "post-alias") == RES_OK && h_fs_Commit("alias") == RES_OK && same(path, "post-alias"), "the clean transaction after alias recovery commits normally");
    CHECK(write_save("save:/a", "pending") == RES_OK, "stage bytes before validation tests"); n = dm_fs_commit_count();
    const char *unknown[] = {"save", "absent"}, *null_name[] = {"save", NULL};
    CHECK(commit(unknown, 2) != RES_OK && same(path, "post-alias"), "unknown name rejects the whole request before any commit");
    CHECK(commit(null_name, 2) != RES_OK, "null name rejected");
    CHECK(commit(NULL, 1) != RES_OK && commit(one, -1) != RES_OK && commit(one, MAX_MOUNT + 1) != RES_OK, "invalid pointer/count combinations rejected");
    CHECK(commit(NULL, 0) == RES_OK, "empty list is a no-op");
    CHECK(mount("rom", root, 1) == RES_OK, "mount non-save input"); const char *non_save[] = {"save", "rom"};
    CHECK(commit(non_save, 2) != RES_OK && same(path, "post-alias"), "read-only mount cannot produce partial success");
    CHECK(dm_fs_commit_count() == n, "rejected/empty lists do not publish");
    if (geteuid() != 0) {
        CHECK(chmod(root, 0500) == 0, "refuse creation of commit snapshot");
        Result denied = commit(one, 1); chmod(root, 0700);
        CHECK(denied != RES_OK && same(path, "post-alias") && dm_fs_commit_count() == n, "clone failure propagates; committed data unchanged");
        CHECK(commit(one, 1) == RES_OK && same(path, "pending"), "retry after snapshot failure commits the same staged bytes");
    } else puts("SKIP permission failure injection when running as root");
    snprintf(bpath, sizeof bpath, "%s/temp", root); setenv("DM_TEMP", bpath, 1);
    CHECK(h_fs_MountCache("cache", 0) == RES_OK, "mount cache storage (writable, no host transaction)");
    const char *with_cache[] = {"save", "cache"}, *cache_only[] = {"cache"};
    CHECK(write_save("save:/a", "with-cache") == RES_OK, "stage bytes beside cache storage"); n = dm_fs_commit_count();
    CHECK(commit(with_cache, 2) == RES_OK && same(path, "with-cache") && dm_fs_commit_count() == n + 1, "save + cache storage commits the save once");
    CHECK(commit(cache_only, 1) == RES_OK && dm_fs_commit_count() == n + 1, "cache storage alone is a no-op, as the single-name Commit");
    snprintf(other, sizeof other, "%s/other", root); mkdir(other, 0755);
    snprintf(bpath, sizeof bpath, "%s/a", other); put(bpath, "old-B"); setenv("DM_SAVE", other, 1);
    CHECK(h_fs_MountSave("other", NULL) == RES_OK, "mount independent transaction");

    // A failed write truncates A's working file first. Committing B must not
    // consume A's failure state, regardless of which independent save commits first.
    fail_write = 1; write_calls = 0;
    CHECK(write_save("save:/a", "bad") == RES_FAIL, "inject a failed write after truncating save A");
    fail_write = 0;
    CHECK(write_save("other:/a", "clean-B") == RES_OK, "write save B cleanly after A fails");
    n = dm_fs_commit_count(); nf = g_nfail;
    CHECK(h_fs_Commit("other") == RES_OK && same(bpath, "clean-B") && same(path, "with-cache"), "B commits independently while A is poisoned");
    CHECK(dm_fs_commit_count() == n + 1 && g_nfail == nf, "B commit is counted without reporting A's failure");
    CHECK(h_fs_Commit("save") != RES_OK && same(path, "with-cache") && same(bpath, "clean-B"), "A commit is refused and its old committed bytes survive");
    CHECK(dm_fs_commit_count() == n + 1 && g_nfail == nf + 1, "only A's failed commit is refused and reported");

    fail_write = 1; write_calls = 0;
    CHECK(write_save("other:/a", "bad") == RES_FAIL, "inject a failed write after truncating save B");
    fail_write = 0;
    CHECK(write_save("save:/a", "clean-A") == RES_OK, "write save A cleanly after B fails");
    n = dm_fs_commit_count(); nf = g_nfail;
    CHECK(h_fs_Commit("save") == RES_OK && same(path, "clean-A") && same(bpath, "clean-B"), "A commits independently while B is poisoned");
    CHECK(dm_fs_commit_count() == n + 1 && g_nfail == nf, "A commit does not consume B's failure state");
    CHECK(h_fs_Commit("other") != RES_OK && same(path, "clean-A") && same(bpath, "clean-B"), "B commit is refused and preserves its old committed bytes");
    CHECK(dm_fs_commit_count() == n + 1 && g_nfail == nf + 1, "only B's failed commit is refused and reported");

    CHECK(h_fs_CreateFile("other:/rename-source", 0) == RES_OK, "create a file for save-B rename failure coverage");
    setenv("DM_TEST_FS_FAILAT", "guestname:1,renameback:1", 1);
    CHECK(h_fs_RenameFile("other:/rename-source", "other:/rename-target") != RES_OK, "inject metadata and rollback failures while renaming in save B");
    unsetenv("DM_TEST_FS_FAILAT");
    n = dm_fs_commit_count(); nf = g_nfail;
    CHECK(h_fs_Commit("save") == RES_OK && same(path, "clean-A"), "rename failure in B does not poison save A");
    CHECK(h_fs_Commit("other") != RES_OK && same(bpath, "clean-B"), "rename failure poisons the affected save B");
    CHECK(dm_fs_commit_count() == n + 1 && g_nfail == nf + 1, "only B's rename-damaged transaction is refused");

    const char *multi[] = {"save", "other"}; n = dm_fs_commit_count();
    CHECK(commit(multi, 2) != RES_OK, "independent multi-save atomic commit explicitly unsupported");
    CHECK(same(path, "clean-A") && same(bpath, "clean-B") && dm_fs_commit_count() == n, "unsupported request publishes neither transaction");

    // No synchronization between mounting and failed fd I/O: the TSan target
    // must catch any access to the mutable mount count from the failure path.
    failed_io io = {0};
    CHECK(h_fs_OpenFile(&io.h, "other:/a", MODE_WRITE) == RES_OK, "open B before concurrent mount");
    CHECK(h_fs_SetFileSize(io.h, 3) == RES_OK, "truncate B before concurrent failure");
    fail_write = 1; write_calls = 0;
    pthread_t writer;
    if (pthread_create(&writer, NULL, fail_save_io, &io)) return 2;
    CHECK(h_fs_MountSave("other-alias", NULL) == RES_OK, "mount an alias while B's fd I/O fails");
    if (pthread_join(writer, NULL)) return 2;
    fail_write = 0;
    h_fs_CloseFile(io.h);
    CHECK(io.write_result == RES_FAIL && io.size_result == RES_FAIL, "both fd failure paths ran");
    CHECK(write_save("save:/a", "after-race") == RES_OK, "stage a clean independent save");
    n = dm_fs_commit_count(); nf = g_nfail;
    CHECK(h_fs_Commit("save") == RES_OK && same(path, "after-race"), "concurrent mount and B failure leave A committable");
    CHECK(h_fs_Commit("other-alias") != RES_OK && same(bpath, "clean-B"), "new alias refuses B's damaged data");
    CHECK(dm_fs_commit_count() == n + 1 && g_nfail == nf + 1, "only B's failure is reported");
    CHECK(write_save("other:/a", "recovered") == RES_OK && h_fs_Commit("other") == RES_OK && same(bpath, "recovered"), "B can save after recovery");
    rm_tree(root);
    printf("list Commit: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
