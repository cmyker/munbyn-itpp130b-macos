/* Synthetic helper-lifetime fixture. No printer, CUPS request or BLE access. */
#include "CBridge.h"
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

int main(int argc,char **argv) {
    if (argc != 3) return 2;
    int owner[2],ready[2]; if (pipe(owner) || pipe(ready)) return 3;
    pid_t child = fork(); if (child < 0) return 4;
    if (child == 0) {
        close(owner[1]); close(ready[0]);
        if (mb_recovery_watchdog(owner[0],!strcmp(argv[1],"deadline") ? 0.2 : 5)) _exit(5);
        FILE *pid = fopen(argv[2],"w"); if (!pid) _exit(6);
        fprintf(pid,"%d",getpid()); fclose(pid);
        char started = 1; if (write(ready[1],&started,1) != 1) _exit(7); close(ready[1]);
        for (;;) pause(); /* stands in for an indefinitely blocked native RPC */
    }
    close(owner[0]); close(ready[1]);
    char started; if (read(ready[0],&started,1) != 1) return 8; close(ready[0]);
    if (!strcmp(argv[1],"parent-exit")) _exit(0); /* kernel closes owner[1] */
    int status; waitpid(child,&status,0); close(owner[1]);
    return WIFEXITED(status) && WEXITSTATUS(status) == 75 ? 0 : 9;
}
