#!/bin/sh
# Drives the built app's aeroops-mcp for `AeroOps -AeroSelfTest phase7`
# (App/Support/Phase7SelfTest.swift). The app starts this script once its bridge listens on
# a temporary socket and the dev hosts are online; the app answers the approval requests
# itself, through ApprovalCenter.decide, as the panel buttons would.
#
# Usage: AEROOPS_BRIDGE_SOCKET=<socket> dev/selftest/phase7-drive.sh <aeroops-mcp> <results-dir>
#
# Every step runs with stdin from /dev/null and a time limit. For step NN-name it writes
# NN-name.out (stdout) and NN-name.err (stderr) to <results-dir> and appends
# "NN-name<TAB>exit status<TAB>seconds<TAB>start (Unix time)" to <results-dir>/steps.tsv.
# A failing step does not stop the run; the app checks the results.
#
# MCP calls go through the MCP Inspector CLI, and two prompts through `claude -p` with a
# temporary --mcp-config and --strict-mcp-config. Nothing in the user's Claude, Codex or
# other agent configuration is read for MCP servers or written.
set -u

[ $# -eq 2 ] || { echo "usage: $0 <aeroops-mcp> <results-dir>" >&2; exit 2; }
: "${AEROOPS_BRIDGE_SOCKET:?set AEROOPS_BRIDGE_SOCKET to the self-test bridge socket}"
mcp=$1
out=$2
[ -x "$mcp" ] || { echo "not an executable: $mcp" >&2; exit 2; }
case "$mcp$AEROOPS_BRIDGE_SOCKET" in
  *\"*|*\\*) echo "paths with quotes or backslashes are not supported" >&2; exit 2 ;;
esac

PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH
inspector=@modelcontextprotocol/inspector@2.10.1

mkdir -p "$out"
: > "$out/steps.tsv"
n=0

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# step NAME LIMIT COMMAND...: runs COMMAND, killed (SIGALRM) after LIMIT seconds.
step() {
  name=$1
  limit=$2
  shift 2
  n=$((n + 1))
  id=$(printf '%02d-%s' "$n" "$name")
  start=$(now)
  perl -e '$t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' "$limit" "$@" \
    </dev/null >"$out/$id.out" 2>"$out/$id.err"
  status=$?
  end=$(now)
  seconds=$(perl -e 'printf "%.3f", $ARGV[1] - $ARGV[0]' "$start" "$end")
  printf '%s\t%s\t%s\t%s\n' "$id" "$status" "$seconds" "$start" >> "$out/steps.tsv"
  echo "[drive] $id: exit $status after $seconds s"
}

# call NAME TOOL ARGUMENTS-JSON: one tools/call through the inspector.
call() {
  step "$1" 120 npx -y "$inspector" --cli "$mcp" -e "AEROOPS_BRIDGE_SOCKET=$AEROOPS_BRIDGE_SOCKET" \
    --method tools/call --tool-name "$2" --tool-args-json "$3"
}

# 1. Discovery and the read tools.
step tools-list 120 npx -y "$inspector" --cli "$mcp" -e "AEROOPS_BRIDGE_SOCKET=$AEROOPS_BRIDGE_SOCKET" \
  --method tools/list
call list-hosts list_hosts '{}'
call metrics-dev-container get_host_metrics '{"host":"dev-container"}'
call metrics-staging get_host_metrics '{"host":"staging"}'
call metrics-alpine get_host_metrics '{"host":"alpine"}'
call containers-staging list_containers '{"host":"staging","all":true}'
call logs-demo-logger get_logs '{"host":"staging","kind":"container","name":"demo-logger","tail":100}'

# 2. run_command. The app approves, denies or cancels each one as Phase7SelfTest describes.
call run-read-host run_command '{"host":"dev-container","command":"uname -a","reason":"Self-test: exec on a Read host must be rejected without asking."}'
call run-allow-once run_command '{"host":"staging","command":"uname -a","reason":"Self-test: the app allows this once."}'
call run-denied run_command '{"host":"staging","command":"uname -a","reason":"Self-test: the app denies this one."}'
call run-allow-window run_command '{"host":"staging","command":"hostname","reason":"Self-test: the app allows the host for 15 minutes."}'
call run-in-window run_command '{"host":"staging","command":"uptime","reason":"Self-test: runs inside the allow window without asking."}'
call run-sudo run_command '{"host":"staging","command":"sudo -n true","reason":"Self-test: sudo asks even inside an allow window."}'
call run-cancelled run_command '{"host":"staging","command":"sleep 120","reason":"Self-test: the app cancels this from the Activity tab.","timeoutSec":150}'

# 3. Claude Code, one run per prompt, read tools only, MCP servers from this file only.
work=$(mktemp -d "${TMPDIR:-/tmp}/aero-st7-claude.XXXXXX") || exit 1
printf '{"mcpServers":{"aeroops":{"command":"%s","env":{"AEROOPS_BRIDGE_SOCKET":"%s"}}}}\n' \
  "$mcp" "$AEROOPS_BRIDGE_SOCKET" > "$work/mcp.json"
cp "$work/mcp.json" "$out/claude-mcp.json"
tools=mcp__aeroops__list_hosts,mcp__aeroops__get_host_metrics,mcp__aeroops__list_containers,mcp__aeroops__list_pods,mcp__aeroops__get_logs
cd "$work" || exit 1
for prompt in "which of my servers uses the most memory?" \
              "show the last 100 lines of the demo-logger container on staging"; do
  case "$prompt" in
    which*) name=claude-memory ;;
    *) name=claude-logs ;;
  esac
  step "$name" 300 claude -p "$prompt" --mcp-config "$work/mcp.json" --strict-mcp-config \
    --setting-sources project --no-session-persistence --output-format json --allowedTools "$tools"
done
cd / && rm -rf "$work"
echo "[drive] done"
