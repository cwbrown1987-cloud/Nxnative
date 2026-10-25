// In-process program switch (DM_PROGRAM_SWITCH=inproc, progswitch.c)
#pragma once
#include <setjmp.h>
#include <stddef.h>
typedef struct {
    int index;                                // the program that starts
    const char *(*apply)(void *arg);          // sets its environment (DM_PROGRAM, DM_ROMFS, DM_LAUNCH_PARAM, …, the working folder) once the run's statics are reset; returns its modules folder
    void *arg;
    void (*fallback)(void *arg);              // what ExecuteProgram does without the switch, when a guest thread does not leave
    void *fallback_arg;
} dm_switch_req;
int dm_program_switch_inproc(void);           // DM_PROGRAM_SWITCH=inproc
int dm_program_switch_request(const dm_switch_req *r);   // on the guest thread in ExecuteProgram: 1 = under way, the thread has left; 0 = not switching here
int dm_program_switch_park(int *argc, char ***argv);     // main.c, the main guest thread at its exit point: 1 = run the boot path again with these arguments
void dm_runstate_snapshot(void);              // at process start
size_t dm_runstate_restore(void);
void dm_thread_set_exit_point(sigjmp_buf *jb);   // hle_thread.c: the main guest thread's exit point
void dm_thread_main_left(void);
