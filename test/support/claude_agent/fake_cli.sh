#!/usr/bin/env bash
# Fake `claude` binary for the :claude_agent provider tests.
#
# - `--version` prints REQ_LLM_FAKE_CLAUDE_VERSION (default 2.1.119) and exits 0.
# - Otherwise reads a JSONL fixture from REQ_LLM_FAKE_CLAUDE_FIXTURE. The first
#   line of the fixture is a JSON header `{"exit_code":N,"stderr":"..."}`.
#   Remaining lines are emitted verbatim on stdout. The header's `stderr`
#   value (if any) is written to stderr before the events are emitted, and the
#   process exits with the header's `exit_code`.

set -u

for arg in "$@"; do
  if [ "$arg" = "--version" ]; then
    echo "${REQ_LLM_FAKE_CLAUDE_VERSION:-2.1.119}"
    exit 0
  fi
done

if [ -z "${REQ_LLM_FAKE_CLAUDE_FIXTURE:-}" ]; then
  echo "FAKE-CLI: REQ_LLM_FAKE_CLAUDE_FIXTURE not set" >&2
  exit 2
fi

if [ ! -f "$REQ_LLM_FAKE_CLAUDE_FIXTURE" ]; then
  echo "FAKE-CLI: fixture not found: $REQ_LLM_FAKE_CLAUDE_FIXTURE" >&2
  exit 2
fi

# Drain stdin in the background so the parent doesn't block on writes.
cat > /dev/null &
DRAINER_PID=$!

# Read header (first line) and event lines.
header=""
events_tmp=$(mktemp)
trap 'rm -f "$events_tmp"' EXIT

{
  read -r header
  cat > "$events_tmp"
} < "$REQ_LLM_FAKE_CLAUDE_FIXTURE"

# Extract exit_code and stderr from the header using sed/grep.
exit_code=$(printf '%s' "$header" | sed -n 's/.*"exit_code"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p')
[ -z "$exit_code" ] && exit_code=0

stderr_msg=$(printf '%s' "$header" | sed -n 's/.*"stderr"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -n "$stderr_msg" ]; then
  printf '%b' "$stderr_msg" >&2
fi

# Emit each event line on stdout.
while IFS= read -r line; do
  printf '%s\n' "$line"
done < "$events_tmp"

# Wait briefly for the stdin drainer (no-op if the parent has already closed).
wait "$DRAINER_PID" 2>/dev/null || true

exit "$exit_code"
