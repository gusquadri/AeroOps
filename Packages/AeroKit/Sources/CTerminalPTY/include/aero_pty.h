#ifndef AERO_PTY_H
#define AERO_PTY_H

#include <sys/types.h>

pid_t aero_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     unsigned short rows, unsigned short columns,
                     unsigned short width_pixels, unsigned short height_pixels,
                     int *master_fd);

int aero_pty_set_size(int fd, unsigned short rows, unsigned short columns,
                      unsigned short width_pixels, unsigned short height_pixels);

#endif
