#!/usr/bin/env bash
# Generate the IntelliJ MCP "Stdio Config" — the JSON that Settings -> Tools ->
# MCP Server -> "Copy Stdio Config" emits — WITHOUT the manual copy, so Step 1 of
# the skill can be automated.
#
# It reconstructs the exact command/classpath/env the bundled mcpserver stdio
# runner needs. Classpath is layout-aware, keyed on the runner jar name:
#   2026.2+   mcpserver.jar          -> `plugins/mcpserver/lib/*:lib/*` glob
#   <=2026.1  mcpserver-frontend.jar -> fixed curated platform-lib list
# If neither runner jar is present (deeper layout drift), the script does NOT
# guess: it FAILS and tells you to use the manual Copy-Stdio-Config button.
# Manual is the always-correct fallback; this is only the fast path.
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

# --- classpath: layout-aware (IDE version bumps rename/relocate jars) ----------
# Two known layouts, distinguished by the mcpserver runner jar name:
#   2026.2+   plugins/mcpserver/lib/mcpserver.jar          (ktor/kotlinx bundled
#             in-plugin; curated platform-lib list no longer resolves)
#   <=2026.1  plugins/mcpserver/lib/mcpserver-frontend.jar (needs curated
#             platform libs from Contents/lib)
# New layout uses a `dir/*` glob classpath (java expands it; extra jars are inert
# and it was verified to launch + list tools). Old layout keeps the curated list
# it was known-good with. Neither jar present -> real drift -> manual button.
plugin_lib="$app/Contents/plugins/mcpserver/lib"
[ -d "$plugin_lib" ] || fallback "mcpserver plugin dir missing: $plugin_lib (MCP Server plugin disabled/absent -> enable it, or use manual copy)"

if [ -f "$plugin_lib/mcpserver.jar" ]; then
  # 2026.2+ : glob the plugin lib + platform lib. Literal `*` — java expands it,
  # NOT the shell (kept verbatim in the emitted JSON args).
  cp="$app/Contents/plugins/mcpserver/lib/*:$app/Contents/lib/*"
  layout="glob (2026.2+)"
elif [ -f "$plugin_lib/mcpserver-frontend.jar" ]; then
  # <=2026.1 : curated fixed set, exact order, each verified present.
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
  layout="curated (<=2026.1, ${#rel_jars[@]} jars)"
else
  fallback "no mcpserver runner jar (mcpserver.jar / mcpserver-frontend.jar) in $plugin_lib (IDE layout drifted -> use manual copy)"
fi

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
logf OK "generated $out (port $port, classpath: $layout)"
echo "Wrote $out (port $port, classpath: $layout)."
echo "Next: scripts/03-setup-mcp.sh <repo-dir> $out"
