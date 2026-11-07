#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

derived=build/DerivedData-quality
work="$(mktemp -d /tmp/aero-ft-XXXXXX)"
socket="$work/bridge.sock"
harness_pid=""
cleanup() {
  [ -n "$harness_pid" ] && kill "$harness_pid" 2>/dev/null && wait "$harness_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

xcodebuild -scheme AeroOps -destination 'platform=macOS' -allowProvisioningUpdates -derivedDataPath "$derived" -quiet build
swift build --package-path Packages/AeroKit --product BridgeHarness -q
harness="$(swift build --package-path Packages/AeroKit --show-bin-path)/BridgeHarness"

"$harness" --socket "$socket" --allow-unsigned-peers > "$work/harness.out" 2> "$work/harness.err" &
harness_pid=$!
deadline=$((SECONDS + 30))
until grep -q '^ready ' "$work/harness.out" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ] || ! kill -0 "$harness_pid" 2>/dev/null; then
    echo "file-tools: FAIL (BridgeHarness did not print 'ready' within 30 s: $(tail -n 3 "$work/harness.err"))"
    exit 1
  fi
  sleep 0.2
done
root="$(sed -n 's/^sftp-root //p' "$work/harness.out")"

mkdir "$work/agent"
printf 'disk 91%%\n' > "$work/agent/report.txt"
cd "$work/agent"
AEROOPS_BRIDGE_SOCKET="$socket" python3 -I - "$OLDPWD/$derived/Build/Products/Debug/aeroops-mcp" "$root" <<'PY'
import json, os, signal, subprocess, sys

mcp, root = sys.argv[1], sys.argv[2]
waiting = ["start"]
signal.signal(signal.SIGALRM, lambda *_: sys.exit(f"file-tools: FAIL (no reply to {waiting[0]} within 60 s)"))
signal.alarm(60)
proc = subprocess.Popen([mcp], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
ids = iter(range(1, 100))

def send(method, params, notify=False):
    message = {"jsonrpc": "2.0", "method": method, "params": params}
    if not notify:
        message["id"] = next(ids)
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()
    while not notify:
        reply = json.loads(proc.stdout.readline() or sys.exit(f"file-tools: FAIL (aeroops-mcp exited during {method})"))
        if reply.get("id") == message["id"]:
            return reply

def call(tool, **arguments):
    waiting[0] = tool
    result = send("tools/call", {"name": tool, "arguments": arguments})["result"]
    return result.get("isError", False), result.get("structuredContent") or {}, result["content"][0]["text"]

def check(condition, what):
    if not condition:
        sys.exit(f"file-tools: FAIL ({what})")

send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "usage", "version": "1"}})
send("notifications/initialized", {}, notify=True)

failed, data, _ = call("upload_file", host="staging", localPath="report.txt", remotePath="uploads-report.txt")
check(not failed and data.get("bytes") == 9, f"upload_file: {data}")
check(open(os.path.join(root, "uploads-report.txt")).read() == "disk 91%\n", "uploaded bytes differ")

failed, data, _ = call("list_files", host="staging")
check(not failed and [e["name"] for e in data["entries"]] == ["uploads-report.txt"], f"list_files: {data}")

failed, data, _ = call("download_file", host="staging", remotePath="uploads-report.txt", localPath="copy.txt")
check(not failed and open("copy.txt").read() == "disk 91%\n", f"download_file: {data}")

failed, _, text = call("download_file", host="staging", remotePath="uploads-report.txt", localPath="copy.txt")
check(failed and "already exists" in text, f"second download was not refused: {text}")

failed, _, text = call("upload_file", host="prod", localPath="report.txt", remotePath="x")
check(failed and "read tools only" in text, f"Read-tier host accepted upload_file: {text}")

failed, _, text = call("upload_file", host="staging", localPath="missing.txt", remotePath="x")
check(failed and "No such file" in text, f"missing local file was not refused: {text}")

proc.stdin.close()
proc.wait(timeout=10)
PY
echo "file-tools: aeroops-mcp uploads, lists and downloads over SFTP; relative local paths resolve from its working directory; existing files, missing files and Read-tier hosts are refused"
