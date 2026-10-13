#include "aero_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static void close_keeping_errno(int fd) {
    int saved = errno;
    close(fd);
    errno = saved;
}

int aero_pty_set_size(int fd, unsigned short rows, unsigned short columns,
                      unsigned short width_pixels, unsigned short height_pixels) {
    struct winsize size = {
        .ws_row = rows,
        .ws_col = columns,
        .ws_xpixel = width_pixels,
        .ws_ypixel = height_pixels,
    };
    return ioctl(fd, TIOCSWINSZ, &size);
}

pid_t aero_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     unsigned short rows, unsigned short columns,
                     unsigned short width_pixels, unsigned short height_pixels,
                     int *master_fd) {
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master == -1) return -1;
    if (fcntl(master, F_SETFD, FD_CLOEXEC) == -1 || grantpt(master) == -1 || unlockpt(master) == -1) {
        close_keeping_errno(master);
        return -1;
    }
    char name[128];
    if (ptsname_r(master, name, sizeof name) != 0) {
        close_keeping_errno(master);
        return -1;
    }
    int slave = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (slave == -1) {
        close_keeping_errno(master);
        return -1;
    }

    // macOS leaves IUTF8 off, which breaks erasing multi-byte characters in canonical mode.
    struct termios attributes;
    if (tcgetattr(slave, &attributes) == 0) {
        attributes.c_iflag |= IUTF8;
        tcsetattr(slave, TCSANOW, &attributes);
    }
    aero_pty_set_size(slave, rows, columns, width_pixels, height_pixels);

    // Everything the child needs is prepared here: after fork only async-signal-safe calls.
    int max_fd = getdtablesize();
    if (max_fd < 0 || max_fd > 65536) max_fd = 65536;
    sigset_t all_signals, no_signals, previous;
    sigfillset(&all_signals);
    sigemptyset(&no_signals);
    struct sigaction default_action = { 0 };
    default_action.sa_handler = SIG_DFL;
    sigemptyset(&default_action.sa_mask);

    // Blocked across fork so no parent handler runs in the child before the reset below.
    pthread_sigmask(SIG_SETMASK, &all_signals, &previous);
    pid_t pid = fork();
    if (pid == 0) {
        for (int signal_number = 1; signal_number < NSIG; signal_number++) {
            sigaction(signal_number, &default_action, NULL);
        }
        sigprocmask(SIG_SETMASK, &no_signals, NULL);

        setsid();
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        for (int fd = STDERR_FILENO + 1; fd < max_fd; fd++) {
            close(fd);
        }
        if (cwd != NULL) {
            // A missing directory is not fatal: the program starts where the app runs.
            (void)chdir(cwd);
        }
        execve(path, argv, envp);
        _exit(127);
    }
    int fork_error = errno;
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    close(slave);
    if (pid == -1) {
        close(master);
        errno = fork_error;
        return -1;
    }
    *master_fd = master;
    return pid;
}
