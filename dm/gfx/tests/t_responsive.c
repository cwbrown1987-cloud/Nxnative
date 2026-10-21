// Cap-only presentation must recover immediately while keeping game time bounded.
#include "../nvn/nvn_fstep.h"
#include <stdio.h>

static int checks, failed;
static void check(int ok, const char *name) {
    checks++; failed += !ok;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
}
int main(void) {
    nvn_fstep s = {0};
    double real = 0, game = 0;
    nvn_fstep_responsive(&s, 0, 1, 0);
    for (int i=0; i<600; i++) {
        // Physical refresh quantization at 165 Hz: three 18.18 ms frames,
        // then one 12.12 ms frame. Average is exactly 60 fps.
        double shown = (i%4 ? 3.0 : 2.0) * 60/165;
        real += shown; game += s.step;
        nvn_fstep_responsive(&s, shown, 1, 0);
    }
    check(s.k==1 && fabs(real-game)<1.01, "165 Hz quantization: no lower hold and no speed drift");
    int held = 1;
    for (int i=0; i<600; i++) {
        real += 1.32; game += s.step;
        nvn_fstep_responsive(&s, 1.32, 1, 0); held &= s.k==1;
    }
    check(held && s.ups==0 && s.downs==0, "22 ms workload: keep cap-only presentation, never deliberately lock 30");
    check(fabs(real-game)<2.01, "22 ms workload: game time follows elapsed time within two vsyncs");
    nvn_fstep_responsive(&s, 30, 1, 0);
    check(s.k==1 && s.debt<=2 && s.dropped>20, "500 ms load: discard excess time without a low-FPS hold");
    int compensated=0;
    for (int i=0; i<8; i++) {
        compensated += s.step>1;
        nvn_fstep_responsive(&s, 1, 1, 0);
    }
    check(compensated<=2 && s.k==1 && s.step==1, "normal rendering resumes immediately; catch-up lasts at most two frames");
    nvn_fstep_responsive(&s, 1, 1, 2);
    check(s.k==2 && s.step==2 && s.debt==0, "respect the game's fixed scene interval");
    nvn_fstep_responsive(&s, 2, 1, 0);
    check(s.k==1 && s.step==1 && s.debt==0, "scene override ends: return directly to 60 without a trial");
    for (int i=0;i<100;i++) nvn_fstep_responsive(&s,2,2,0);
    check(s.k==2 && s.step==2 && s.debt==0, "explicit 30 FPS cap stays at 30");
    nvn_fstep_responsive(&s,2,1,0);
    check(s.k==1 && s.step==1 && s.debt==0, "raising cap clears stale timing debt");
    printf("%d checks, %d failed\n",checks,failed);
    return failed != 0;
}
