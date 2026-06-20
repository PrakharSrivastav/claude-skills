#!/usr/bin/env bash
# Generate the IntelliJ MCP "Stdio Config" — the JSON that Settings -> Tools ->
# MCP Server -> "Copy Stdio Config" emits — WITHOUT the manual copy, so Step 1 of
# the skill can be automated.
#
# It reconstructs the exact command/classpath/env the bundled mcpserver stdio
# runner needs. The classpath is a FIXED, curated list (one plugin jar + a
# specific set of platform libs), captured from a known-good config — NOT a glob,
# because the dir holds jars the runner must NOT be on the classpath. If the IDE
# layout drifts (any listed jar missing), the script does NOT guess: it FAILS and
# tells you to use the manual Copy-Stdio-Config button. Manual is the always-
# correct fallback; this is only the fast path.
#
# Usage: 02-make-stdio-config.sh [out.json]      (default: /tmp/ij-mcp.json)
# Env:   IDE_APP             override IDE .app path
#        IJ_MCP_SERVER_PORT  override port (default 64342)
set -uo pipefail

out="${1:-/tmp/ij-mcp.json}"

# Field log (see SKILL.md "Feedback loop"): record every fallback so layout drift
# in the curated jar list surfaces as durable signal. Local, append-only.
FIELDLOG="${FIELDLOG:-$(cd "$(dirname "$0")/.." && pwd)/.fieldlog}"
logf() { printf '%s\t02\t%s\t%s\n' "$(date +%FT%T)" "$1" "$2" >>"$FIELDLOG" 2>/dev/null || true; }

[ "$(uname)" = "Darwin" ] || { echo "This skill is scoped to macOS + IntelliJ IDEA." >&2; exit 2; }

fallback() {
  logf FAIL "$1"
  echo "Could not auto-generate stdio config: $1" >&2
  echo "Fall back to the manual (always-correct) path:" >&2
  echo "  IDEA -> Settings -> Tools -> MCP Server -> Copy Stdio Config, then:" >&2
  echo "  pbpaste > $out" >&2
  exit 1
}

# --- locate the IDE app (same strategy as 01-check-prereqs.sh) ----------------
app="${IDE_APP:-}"
if [ -z "$app" ]; then
  launcher="$(command -v idea 2>/dev/null || true)"
  if [ -n "$launcher" ]; then
    bin="$(grep -oE 'open -na "[^"]+"' "$launcher" 2>/dev/null | head -1 | sed -E 's/open -na "([^"]+)"/\1/')"
    [ -n "$bin" ] && app="${bin%/Contents/MacOS/*}"
  fi
fi
if [ -z "$app" ]; then
  for cand in "/Applications/IntelliJ IDEA.app" "$HOME/Applications/IntelliJ IDEA.app"; do
    [ -d "$cand" ] && app="$cand" && break
  done
fi
[ -n "$app" ] && [ -d "$app" ] || fallback "IDE app not found (set IDE_APP=/path/to/IntelliJ IDEA.app)"

java="$app/Contents/jbr/Contents/Home/bin/java"
[ -x "$java" ] || fallback "bundled JBR java not found at $java"

# --- classpath: FIXED curated set (from a known-good Copy-Stdio-Config) -------
# Exactly these, in this order. Verified to exist; a miss means the IDE layout
# changed (version bump) and the manual button is authoritative again.
rel_jars=(
  "plugins/mcpserver/lib/mcpserver-frontend.jar"
  "lib/util-8.jar"
  "lib/intellij.libraries.kotlinx.coroutines.core.jar"
  "lib/intellij.libraries.ktor.client.cio.jar"
  "lib/intellij.libraries.ktor.client.jar"
  "lib/intellij.libraries.ktor.network.tls.jar"
  "lib/intellij.libraries.ktor.io.jar"
  "lib/intellij.libraries.ktor.utils.jar"
  "lib/intellij.libraries.kotlinx.io.jar"
  "lib/intellij.libraries.kotlinx.serialization.core.jar"
  "lib/intellij.libraries.kotlinx.serialization.json.jar"
)
cp=""
for rel in "${rel_jars[@]}"; do
  jar="$app/Contents/$rel"
  [ -f "$jar" ] || fallback "expected jar missing: $rel (IDE layout drifted -> use manual copy)"
  cp="${cp:+$cp:}$jar"
done

port="${IJ_MCP_SERVER_PORT:-64342}"
runner="com.intellij.mcpserver.stdio.McpStdioRunnerKt"

# --- emit JSON via python3 (correct escaping for the spaces in app paths) -----
python3 - "$out" "$java" "$cp" "$runner" "$port" <<'PY' || fallback "JSON write failed"
import json, sys
out, java, cp, runner, port = sys.argv[1:6]
cfg = {"type": "stdio", "command": java,
       "args": ["-classpath", cp, runner],
       "env": {"IJ_MCP_SERVER_PORT": port}}
open(out, "w").write(json.dumps(cfg))
PY

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$out" || fallback "generated JSON is invalid"
logf OK "generated $out (port $port, ${#rel_jars[@]} jars)"
echo "Wrote $out (port $port, ${#rel_jars[@]} jars on classpath)."
echo "Next: scripts/03-setup-mcp.sh <repo-dir> $out"
