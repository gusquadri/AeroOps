#ifndef AERO_PTY_H
#define AERO_PTY_H

#include <sys/types.h>

/// Starts `path` on a new pseudo-terminal as the leader of a new session, with the terminal
/// as its controlling terminal and stdin, stdout and stderr.
///
/// `argv` and `envp` are NULL-terminated. `cwd` may be NULL (the child keeps the caller's
/// directory). On success returns the child's pid and stores the master side in `*master_fd`
/// (blocking, close-on-exec); the caller owns it. On failure returns -1 with errno set.
///
/// A fork in a multi-threaded process: the child only makes async-signal-safe calls before
/// `execve`, and exits with 127 when `execve` fails.
pid_t aero_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     unsigned short rows, unsigned short columns,
                     unsigned short width_pixels, unsigned short height_pixels,
                     int *master_fd);

/// Sets the terminal size (TIOCSWINSZ). The kernel sends SIGWINCH to the foreground process
/// group when the size changes. Returns 0, or -1 with errno set.
int aero_pty_set_size(int fd, unsigned short rows, unsigned short columns,
                      unsigned short width_pixels, unsigned short height_pixels);

#endif
