#!/bin/sh
# AeroOps terminfo check. Run before the first terminal tab to a host opens;
# the result is kept until AeroOps quits or installs the entry.
# Run as: ssh aero-<id> 'LC_ALL=C sh -s' < terminfo-check.sh
# Prints one token per line, in this order, only when present:
#   xterm-ghostty  the host has Ghostty's terminfo entry, so tabs can run with
#                  TERM=xterm-ghostty instead of xterm-256color
#   tic            tic is installed, so terminfo-install.sh can add the entry
# POSIX sh, BusyBox-compatible.
#
# Where infocmp exists it answers, because it looks where the host's curses
# looks. Without it (BusyBox systems) the usual terminfo directories are
# searched, in their letter and hex layouts.
export LC_ALL=C
found=
if command -v infocmp >/dev/null 2>&1; then
  infocmp xterm-ghostty >/dev/null 2>&1 && found=1
else
  dirs=$(printf '%s' "${TERMINFO_DIRS:-}" | tr ':' ' ')
  for dir in "${TERMINFO:-}" "$HOME/.terminfo" $dirs /etc/terminfo /lib/terminfo \
             /usr/share/terminfo /usr/lib/terminfo /usr/local/share/terminfo; do
    [ -n "$dir" ] || continue
    if [ -f "$dir/x/xterm-ghostty" ] || [ -f "$dir/78/xterm-ghostty" ]; then
      found=1
      break
    fi
  done
fi
[ -n "$found" ] && echo xterm-ghostty
command -v tic >/dev/null 2>&1 && echo tic
exit 0
