# AeroOps run_command wrapper (MCP exec tier). POSIX sh, BusyBox-compatible.
# Usage: sh -c '<this script>' aeroops-run COMMAND DEADLINE_SECONDS HEARTBEAT_SECONDS
#
# Runs COMMAND with `sh -c` and exits with its status. A watchdog writes one ACK
# byte (0x06) to stdout every HEARTBEAT_SECONDS; the client removes those bytes.
# When that write fails (the ssh client is gone: sshd closes the channel's stdout,
# also under a ControlMaster) or the command outlives DEADLINE_SECONDS, the
# watchdog kills the whole process group with TERM, then KILL. sshd starts every
# session with setsid, so that group is this command and everything it started
# (unless something detached itself with setsid).
# The wrapper changes no locale or environment: COMMAND runs as the user typed it.
sh -c "$1" &
p=$!
( stop() {
    trap '' TERM
    exec >/dev/null
    kill -s TERM 0 2>/dev/null
    sleep 2 </dev/null >/dev/null 2>&1
    kill -s KILL 0 2>/dev/null
    exit 0
  }
  trap stop PIPE
  t=0
  while sleep "$3" </dev/null >/dev/null 2>&1; do
    t=$((t + $3))
    printf '\006' || stop
    [ "$t" -lt "$2" ] || stop
  done ) </dev/null 2>/dev/null &
w=$!
wait "$p"
s=$?
kill "$w" 2>/dev/null
exit "$s"
