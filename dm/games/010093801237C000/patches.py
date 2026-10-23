# Metroid Dread: rewriter patches of its builds (dm/tools/patch_nso.py loads every profile's patches.py and applies those of the build it rewrites; format in
# dm/games/README.md). Keyed by NSO build ID, as the profile's build rows name them.

# ---- Registered observation gates: {NSO build ID: [(offset, number, original instruction word, reason)]}. Numbers match OBS_* in the host's hle.h;
# the original instruction must be position independent (no PC-relative / branch / anything involving x18 or tpidr), asserted offline; when the host has no callback attached the gate block goes in and out once and returns ----
OBS = {
  # Metroid Dread 2.1.0 main: the movie player posts "link / unlink holders" requests into the dispatcher thread's request ring (main+0x222cc8) and goes on without waiting for them (after an unlink it frees the wrapper object and builds a new one in place).
  # On hardware the dispatcher thread (priority 30, core 0 only) preempts the main thread (priority 44, core 0) at once and finishes first; the host waits for the ring to empty after each post (hle_movie.c movie_ring_wait). The gates sit on the add x22, x22, #8 after the bl
  '646761f643afebb379edd5e6a5151af2': [
    (0x2247a4, 19, '910022d6', 'link request posted (loop at main+0x224728, x19 = request ring): wait for the dispatcher; orig add x22, x22, #8'),
    (0x2248e4, 20, '910022d6', 'unlink request posted (loop at main+0x224868, x19 = request ring): wait for the dispatcher before the object is freed; orig add x22, x22, #8'),
  ],
}
