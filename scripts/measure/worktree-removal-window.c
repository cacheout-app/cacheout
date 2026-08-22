// Measure: t0 = just before we hand control to the remover;
//          t1 = first instant a SENTINEL tracked file inside the worktree is gone.
// mode "git": posix_spawn `git -C <parent> worktree remove <wt>`
// mode "fs" : the re-proved arm's shape - removefile() recursive on the tree
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <time.h>
#include <removefile.h>
#include <fcntl.h>

extern char **environ;

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    // argv: mode parent wt sentinel
    const char *mode = argv[1], *parent = argv[2], *wt = argv[3], *sentinel = argv[4];
    struct stat st;
    if (lstat(sentinel, &st) != 0) { fprintf(stderr, "sentinel missing pre-run\n"); return 2; }

    pid_t pid = 0;
    double t0;
    if (strcmp(mode, "git") == 0) {
        char *args[] = {"git", "-C", (char*)parent, "worktree", "remove", (char*)wt, NULL};
        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
        t0 = now_ms();
        if (posix_spawnp(&pid, "git", &fa, NULL, args, environ) != 0) { perror("spawn"); return 2; }
    } else {
        removefile_state_t s = removefile_state_alloc();
        t0 = now_ms();
        if (fork() == 0) {
            removefile(wt, s, REMOVEFILE_RECURSIVE);
            _exit(0);
        }
    }
    double t1 = -1;
    for (;;) {
        if (lstat(sentinel, &st) != 0 && errno == ENOENT) { t1 = now_ms(); break; }
        if (now_ms() - t0 > 60000) { fprintf(stderr, "timeout\n"); return 3; }
    }
    int status = 0; wait(&status);
    printf("%.3f\n", t1 - t0);
    return 0;
}
