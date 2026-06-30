#!/usr/bin/env bash
#
# mayhem/test.sh — RUN m3u8's own pytest suite (deps already installed by mayhem/build.sh) and
# emit a CTRF (ctrf.io) summary. exit 0 iff failed==0. PATCH-grade oracle: a no-op patch that
# neuters the parser breaks pytest's behavioral assertions, so it FAILS here (anti-reward-hacking).
#
# It does NOT compile — build.sh installed pytest + bottle into the in-image site dir, kept m3u8 on
# PYTHONPATH, and compiled the m3u8_run_tests ELF wrapper. We only RUN the suite. The suite is routed
# through that compiled NON-system wrapper so the gate's sabotage check (neuter non-system binaries
# to exit(0)) actually perturbs the run (the CPython interpreter under /usr/bin would otherwise be
# spared).
#
# Some loader tests fetch from a local bottle server (tests/m3u8server.py on localhost:8112), exactly
# as upstream's ./runtests does — so we start it first and stop it after, mirroring upstream. The
# server talks over loopback only, so it works under `docker run --network none` (lo stays up) — but
# we VERIFY readiness with a real HTTP 200 instead of assuming, fail loudly with the server log if it
# never comes up, and guarantee the port is freed on exit.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

SRC="${SRC:-/mayhem}"
cd "$SRC"

# Put the in-image site dir (atheris + pytest + bottle) and the m3u8 source tree on PYTHONPATH.
PY_PREFIX=/opt/toolchains/python
# shellcheck disable=SC1091
[ -f "$PY_PREFIX/env.sh" ] && source "$PY_PREFIX/env.sh"
export PYTHONPATH="$PY_PREFIX/site:$SRC${PYTHONPATH:+:$PYTHONPATH}"

PY="${PYTHON_BIN:-$(command -v python3)}"

SERVER_HOST=localhost
SERVER_PORT=8112
SERVER_URL="http://$SERVER_HOST:$SERVER_PORT/simple.m3u8"
SERVER_LOG=/tmp/m3u8server.log

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/m3u8_run_tests"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing/not executable — mayhem/build.sh must build it first" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

# ── Local test server (tests/m3u8server.py, bottle, localhost:8112) ──────────────────────────────
# Reusable HTTP-200 probe against the bottle server, run via the interpreter (no curl/wget needed,
# and it stays inside loopback so it works under --network none).
server_ready() {
  "$PY" - "$SERVER_URL" <<'PY' 2>/dev/null
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=1) as r:
        sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
}

SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    # Kill the whole process group so no bottle child survives to hold the port.
    kill "$SERVER_PID" 2>/dev/null || true
    kill -- -"$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# A stray server from a prior run could already own the port. If one is up AND already serving our
# fixtures, reuse it; otherwise reap whatever is squatting on 8112 so our fresh server can bind.
if server_ready; then
  echo "test.sh: a server is already serving $SERVER_URL — reusing it"
else
  if "$PY" - "$SERVER_PORT" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
sys.exit(0 if s.connect_ex(("localhost", int(sys.argv[1]))) == 0 else 1)
PY
  then
    echo "test.sh: port $SERVER_PORT is held by a stale process — reaping it" >&2
    # fuser is available on the build base; fall back to a no-op if not.
    fuser -k "${SERVER_PORT}/tcp" 2>/dev/null || true
    sleep 0.5
  fi
fi

# Start our own server in its own process group (setsid) so cleanup can take the whole group down.
if ! server_ready; then
  setsid "$PY" "$SRC/tests/m3u8server.py" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  # Wait for a real HTTP 200 from the server (not just a TCP accept) — up to ~12s.
  ready=0
  for _ in $(seq 1 60); do
    if server_ready; then ready=1; break; fi
    # If the server process died, stop waiting and report immediately.
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
    sleep 0.2
  done
  if [ "$ready" -ne 1 ]; then
    echo "test.sh: local test server never became ready on $SERVER_URL" >&2
    echo "----- $SERVER_LOG -----" >&2
    cat "$SERVER_LOG" >&2 || true
    echo "-----------------------" >&2
    emit_ctrf "pytest" 0 1 0
    exit 1
  fi
fi

# Run the suite. -p no:cacheprovider keeps the read-only image happy; tests/ is the project's suite.
# pytest (prepend import mode) inserts tests/ on sys.path so the suite's `import playlists` resolves.
LOG="$(mktemp)"
"$RUNNER" -p no:cacheprovider -o addopts= -q tests/ 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Parse pytest's summary line, e.g. "123 passed, 2 skipped in 0.4s" / "1 failed, 122 passed in ...".
line="$(grep -E '^(=+ )?[0-9].*(passed|failed|error|skipped)' "$LOG" | tail -1)"
get() { echo "$line" | grep -oE "[0-9]+ $1" | grep -oE '^[0-9]+' | head -1; }
passed="$(get passed)";  passed="${passed:-0}"
failed="$(get failed)";  failed="${failed:-0}"
errors="$(get error)";   errors="${errors:-0}"
skipped="$(get skipped)"; skipped="${skipped:-0}"
rm -f "$LOG"

# pytest errors (collection/setup) count as failures for the oracle.
failed=$(( failed + errors ))

# If pytest itself could not run (rc!=0 and no parseable counts), report a failure.
if [ "$(( passed + failed + skipped ))" -eq 0 ] && [ "$rc" -ne 0 ]; then
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

emit_ctrf "pytest" "$passed" "$failed" "$skipped"
