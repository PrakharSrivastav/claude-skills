#!/usr/bin/env bash
# Verify the JetBrains MCP bridge exposes tools, server-side.
#
# This drives the stdio bridge directly with a raw MCP handshake (initialize ->
# tools/list), so it proves the IDE side is healthy independent of whether Claude
# Code registered the tools. Use it to separate an IDE-side problem from
# claude-code#41418 ("connects but zero tools register").
#
# Usage: 04-probe-tools.sh <stdio-config.json>
#   <stdio-config.json>  The "Copy Stdio Config" JSON from the IDE.
# Env:
#   PROBE_WAIT  Seconds to keep stdin open for the server to reply (default 6).
#               Bump it on a cold IDE that is still indexing.
set -euo pipefail
# Field log: record probe failures (0 tools / bridge errors) so real setups feed
# back into the skill (harvested at end of run — see SKILL.md "Feedback loop").
FIELDLOG="${FIELDLOG:-$(cd "$(dirname "$0")/.." && pwd)/.fieldlog}"
logf() { printf '%s\t04\t%s\t%s\n' "$(date +%FT%T)" "$1" "$2" >>"$FIELDLOG" 2>/dev/null || true; }
trap 'logf ERR "probe failed (line $LINENO) — 0 tools or bridge error; see stderr"' ERR
# Read-only probe (spawns a throwaway bridge, lists tools, changes nothing) — so it is
# already idempotent. --dry-run validates args without spawning the bridge.
DRY=0; cfg=""
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; *) cfg="$a" ;; esac; done
: "${cfg:?usage: 04-probe-tools.sh <stdio-config.json> [--dry-run]}"
[ -f "$cfg" ] || { echo "config json not found: $cfg" >&2; exit 1; }
if [ "$DRY" = 1 ]; then echo "[dry-run] would probe $cfg (read-only; no changes either way)"; exit 0; fi

python3 - "$cfg" "${PROBE_WAIT:-6}" <<'PY'
import json, sys, os, subprocess, tempfile, time
cfg = json.load(open(sys.argv[1]))
wait = float(sys.argv[2])
cmd = [cfg["command"]] + cfg.get("args", [])
env = dict(os.environ); env.update(cfg.get("env", {}))
msgs = [
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0.0.1"}}}',
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
]

# Stream stdout to a file (no pipe-buffer limit), and keep stdin OPEN for `wait`
# seconds so the bridge flushes its reply before it sees EOF and cancels.
out = tempfile.NamedTemporaryFile("w+", delete=False)
try:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=out,
                         stderr=subprocess.DEVNULL, text=True, env=env)
    p.stdin.write("\n".join(msgs) + "\n")
    p.stdin.flush()
    time.sleep(wait)
    p.stdin.close()
    try:
        p.wait(timeout=15)
    except subprocess.TimeoutExpired:
        p.terminate()

    tools = []
    out.flush()
    for line in open(out.name):
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if m.get("id") == 2 and "result" in m:
            tools = m["result"].get("tools", [])
finally:
    try: os.unlink(out.name)
    except OSError: pass

print(f"TOOLS REGISTERED: {len(tools)}")
for t in tools:
    print(" -", t["name"])
if not tools:
    print("\n0 tools — check: IDE OPEN? MCP Server enabled in Settings? indexing done?",
          file=sys.stderr)
    sys.exit(1)
PY
