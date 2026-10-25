// Per-run state: the statics of every host file that includes this header (dm.h does) live in the sections __DATA,__dmrun_data / __dmrun_bss instead of __data / __bss.
// An in-process program switch (DM_PROGRAM_SWITCH=inproc, progswitch.c) stops every guest thread and host helper, releases what the subsystems hold, then restores these two
// sections to their state at process start (dm_runstate_restore), which resets every such static at once (counters, tables, locks, once flags, cached pointers) before the boot
// path runs again for the next program. A static that must outlive one program's run (a process-wide registration, the switch's own state) takes DM_PROCESS. The front end
// (front_mac.m, dm/ios/Sources, web_apple.m) opts out after its includes with #pragma clang section bss="" data="": its window, views and controllers live for the process
#pragma once
#pragma clang section bss="__DATA,__dmrun_bss" data="__DATA,__dmrun_data"
#define DM_PROCESS __attribute__((section("__DATA,__data")))
