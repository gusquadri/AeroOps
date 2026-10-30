#!/usr/bin/env bash
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
[ -x Scripts/quality ] || exit 0

input="$(cat)"
max_attempts="${LEAN_CODE_MAX_ATTEMPTS:-1}"

json_field() {
  printf '%s\n' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}[:space:]]*\).*/\1/p" | head -n 1
}

tree_fingerprint() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  {
    git rev-parse -q --verify HEAD
    git diff --cached --binary --no-ext-diff --no-textconv --no-color
    git diff --binary --no-ext-diff --no-textconv --no-color
    git ls-files -o --exclude-standard
    git ls-files -o --exclude-standard | git hash-object --stdin-paths
  } 2>/dev/null | git hash-object --stdin
}

state_file="$(git rev-parse --git-path lean-code-quality 2>/dev/null)"
attempts_file="${TMPDIR:-/tmp}/lean-code-stop-$(json_field session_id)"
turn_file="${TMPDIR:-/tmp}/lean-code-turn-$(json_field session_id)"

if [ "$(json_field hook_event_name)" = UserPromptSubmit ]; then
  tree_fingerprint > "$turn_file"
  exit 0
fi

record() {
  [ -n "$state_file" ] || return 0
  printf '%s %s\n' "$(tree_fingerprint)" "$1" > "$state_file"
}

warn_user() {
  printf '{"systemMessage": "%s"}\n' "$1"
  exit 0
}

next_attempt() {
  [ "$(json_field stop_hook_active)" = "true" ] || { echo 1; return; }
  echo $(( $(cat "$attempts_file" 2>/dev/null || echo 0) + 1 ))
}

last_fingerprint=""
last_result=""
[ -n "$state_file" ] && { read -r last_fingerprint last_result < "$state_file"; } 2>/dev/null
fingerprint="$(tree_fingerprint)"

if [ -n "$fingerprint" ] && [ "$fingerprint" = "$(cat "$turn_file" 2>/dev/null)" ]; then
  exit 0
fi

if [ -n "$fingerprint" ] && [ "$fingerprint" = "$last_fingerprint" ]; then
  [ "$last_result" = pass ] && exit 0
  warn_user "Scripts/quality is still failing and nothing changed since its last run."
fi

if output="$(Scripts/quality 2>&1)"; then
  rm -f "$attempts_file"
  record pass
  exit 0
fi
record fail

attempt="$(next_attempt)"
if [ "$attempt" -gt "$max_attempts" ]; then
  rm -f "$attempts_file"
  warn_user "Scripts/quality still fails after $max_attempts attempts. Claude stopped so you can decide what to do."
fi
echo "$attempt" > "$attempts_file"
printf '%s\n' "$output" | tail -c 3000 >&2
echo "Scripts/quality failed (attempt $attempt of $max_attempts). Fix the failures before finishing." >&2
exit 2
