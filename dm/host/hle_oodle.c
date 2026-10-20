// The game's own Oodle decoder, for the offline shader tools. Unreal Engine games compress each shader in their shader code archives with Oodle (Octopath Traveler 0: every entry of the
// two .ushaderbytecode files in pakchunk0-Switch.pak, block header 8C 0A = Mermaid). Shaders are translated offline only and Oodle's decoder is not open source, so the NSP script decodes
// them once on the Mac with the copy statically linked into main: DM_OODLE_JOB=<job file> runs OodleLZ_Decompress on every record right before nnMain, writes <job file>.out and exits.
// Job file: "DMOJ", u32 count, then per record u32 compressed length, u32 raw length and the compressed bytes. Output: "DMOR", u32 count, then per record u32 decoded length
// (0 = failed) and the decoded bytes. Fixed addresses: each row runs only on the main build it was found in (AGENTS.md)
#include "hle.h"
#include <unistd.h>

static const struct { const char *build, *what; uint64_t off; } k_oodle[] = {
    // Octopath Traveler 0 1.0.5: OodleLZ_Decompress, found by the function name its profiler hook passes (the string at main+0x5696117, referenced at main+0x4f77e64)
    // and its argument checks (compBuf x0, rawBuf x2, rawLen x3, decBufBase x7)
    { "9fe60a212cff9b9a3656ab63d4f882e5", "Octopath Traveler 0 1.0.5", 0x4f77e10 },
};

// OodleLZ_Decompress(compBuf, compBufSize, rawBuf, rawLen, fuzzSafe, checkCRC, verbosity, decBufBase, decBufSize, fpCallback, callbackUserData, decoderMemory, decoderMemorySize, threadPhase).
// Arguments 9-14 go on the stack; all are 64-bit here so the Apple and AAPCS64 stack layouts agree (Apple packs smaller stack arguments)
typedef int64_t (*oodle_fn)(const void *, int64_t, void *, int64_t, int64_t, int64_t, int64_t, void *, int64_t, void *, void *, void *, int64_t, int64_t);

static uint32_t rd32(FILE *f) { uint32_t v = 0; if (fread(&v, 4, 1, f) != 1) die("DM_OODLE_JOB: the job file ends early"); return v; }

void dm_oodle_job_maybe(void) {
    const char *job = getenv("DM_OODLE_JOB");
    if (!job || !*job) return;
    oodle_fn fn = NULL; const char *what = NULL;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main"))
        for (int k = 0; k < (int)(sizeof k_oodle / sizeof k_oodle[0]); k++)
            if (!strcmp(g_mod[i].build_id, k_oodle[k].build)) { fn = (oodle_fn)(void *)(g_mod[i].base + k_oodle[k].off); what = k_oodle[k].what; }
    if (!fn) die("DM_OODLE_JOB: no OodleLZ_Decompress address for main build %s", dm_main_build());
    FILE *in = fopen(job, "rb"); if (!in) die("DM_OODLE_JOB: cannot open %s", job);
    if (rd32(in) != 0x4a4f4d44) die("DM_OODLE_JOB: %s is not a job file", job);
    uint32_t n = rd32(in);
    char outp[1024]; snprintf(outp, sizeof outp, "%s.out", job);
    FILE *out = fopen(outp, "wb"); if (!out) die("DM_OODLE_JOB: cannot write %s", outp);
    uint32_t hdr[2] = {0x524f4d44, n}; fwrite(hdr, 4, 2, out);
    size_t scratch_n = 16u << 20; void *scratch = malloc(scratch_n);   // the decoder's work memory, so Oodle never calls its allocator
    uint32_t bad = 0; uint64_t raw_total = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t cl = rd32(in), rl = rd32(in);
        uint8_t *c = malloc(cl ? cl : 1), *r = malloc(rl ? rl : 1);
        if (fread(c, 1, cl, in) != cl) die("DM_OODLE_JOB: record %u ends early", i);
        int64_t got = fn(c, cl, r, rl, 1, 0, 0, NULL, 0, NULL, NULL, scratch, (int64_t)scratch_n, 3);   // fuzz safe, no CRC check, silent, unthreaded
        uint32_t ol = got == (int64_t)rl ? rl : 0;
        if (!ol && bad++ < 8) LOG("[RED] DM_OODLE_JOB: record %u (%u → %u bytes) failed (decoder returned %lld)", i, cl, rl, (long long)got);
        fwrite(&ol, 4, 1, out); if (ol) fwrite(r, 1, ol, out);
        raw_total += ol; free(c); free(r);
    }
    fclose(in); fclose(out); free(scratch);
    LOG("DM_OODLE_JOB: %u records decoded with %s's OodleLZ_Decompress (%u failed, %.1f MB out) → %s", n - bad, what, bad, raw_total / 1048576.0, outp);
    fflush(stderr); _exit(bad ? 1 : 0);
}
