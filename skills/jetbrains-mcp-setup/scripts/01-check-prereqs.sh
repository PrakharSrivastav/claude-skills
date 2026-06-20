#!/usr/bin/env bash
# Preflight: verify the IDE side is set up before wiring Claude Code to it.
#
# The bundled MCP server only exposes tools when (a) the IDE is new enough to
# ship the `mcpserver` plugin, (b) that plugin is enabled, and (c) "Enable MCP
# Server" is ticked. If any of those is wrong, Claude connects but sees zero
# tools (looks like claude-code#41418 but is actually IDE-side). This script
# tells the user exactly what to fix, in the IDE, before they go further.
#
# Required checks FAIL (exit 1). Repo-specific checks WARN; optional extras INFO.
# This is all STATIC (files only). Runtime state — is indexing done, do tools
# actually register — is not checkable here; run 04-probe-tools.sh for that.
#
# Usage: 01-check-prereqs.sh
# Env:
#   IDE_APP   Path to the IDE .app (default: auto-glob /Applications + ~/Applications).
#   IDE_CFG   Path to the IDE config dir (default: newest ~/Library/.../IntelliJIdea*).
set -uo pipefail

# Scoped to macOS for now: the IDE-install layout (`Contents/...`), the config dir
# (`~/Library/Application Support/JetBrains`), and the `open -na` launcher parse are
# all macOS-specific. Fail fast elsewhere rather than silently mis-detect.
if [ "$(uname)" != "Darwin" ]; then
  echo "This skill is currently scoped to macOS + IntelliJ IDEA." >&2
  echo "Detected $(uname) — follow the manual setup in SKILL.md instead." >&2
  exit 2
fi

# This checker is read-only and idempotent — it inspects files and prints, never writes.
# --dry-run is accepted for a uniform test harness; it runs identically (a note is shown).
for a in "$@"; do [ "$a" = "--dry-run" ] && echo "[dry-run] read-only checker — runs identically, changes nothing"; done

fail=0
# Field log: append every FAIL/WARN so real setups leave durable evidence the skill
# can learn from (harvested at end of run — see SKILL.md "Feedback loop"). Local,
# append-only, safe to delete; override the path with FIELDLOG=. Logging failures
# are swallowed so they can never break the preflight itself.
FIELDLOG="${FIELDLOG:-$(cd "$(dirname "$0")/.." && pwd)/.fieldlog}"
logf() { printf '%s\t01\t%s\t%s\n' "$(date +%FT%T)" "$1" "$2" >>"$FIELDLOG" 2>/dev/null || true; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; logf FAIL "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; logf WARN "$1"; }
info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }

# --- locate the IDE install + config dir (macOS layout) -----------------------
# Primary: the `idea` launcher on PATH (works for Toolbox AND app-bundle installs,
# wherever they live). Toolbox writes a launcher that calls the real binary via
# `open -na "<App>.app/Contents/MacOS/idea"` — pull the .app out of that line.
# Fallback: glob the usual /Applications locations.
app="${IDE_APP:-}"
if [ -z "$app" ]; then
  launcher="$(command -v idea 2>/dev/null || true)"
  if [ -n "$launcher" ]; then
    bin="$(grep -oE 'open -na "[^"]+"' "$launcher" 2>/dev/null | head -1 | sed -E 's/open -na "([^"]+)"/\1/')"
    [ -n "$bin" ] && app="${bin%/Contents/MacOS/*}"   # .../X.app/Contents/MacOS/idea -> .../X.app
  fi
fi
if [ -z "$app" ]; then
  for cand in "/Applications/IntelliJ IDEA.app" "$HOME/Applications/IntelliJ IDEA.app"; do
    [ -d "$cand" ] && app="$cand" && break
  done
fi
cfg="${IDE_CFG:-$(ls -d "$HOME/Library/Application Support/JetBrains/IntelliJIdea"* 2>/dev/null | sort | tail -1)}"

echo "JetBrains MCP preflight"
[ -n "$app" ] && [ -d "$app" ] && ok "IDE app: $app" \
  || { bad "IDE app not found (set IDE_APP=/path/to/IntelliJ IDEA.app)"; echo; echo "Cannot continue — no IDE install located."; exit 1; }
[ -n "$cfg" ] && [ -d "$cfg" ] && ok "IDE config: $cfg" \
  || warn "IDE config dir not found — plugin-enabled + setting checks skipped (first run? open the IDE once)"

disabled="$cfg/disabled_plugins.txt"
is_disabled() { [ -f "$disabled" ] && grep -qix "$1" "$disabled"; }

# --- REQUIRED: bundled mcpserver plugin present + enabled ---------------------
if [ -d "$app/Contents/plugins/mcpserver" ]; then
  ok "mcpserver plugin bundled (IDE is 2025.2+)"
  if is_disabled "com.intellij.mcpServer"; then
    bad "mcpserver plugin is DISABLED → enable it: Settings → Plugins → search \"MCP Server\" → Enable → restart IDE"
  else
    ok "mcpserver plugin enabled"
  fi
else
  bad "mcpserver plugin NOT bundled → IDE too old. Upgrade to IntelliJ IDEA 2025.2+ (Help → Check for Updates)"
fi

# --- REQUIRED: Enable MCP Server setting --------------------------------------
mcpxml="$cfg/options/mcpServer.xml"
if [ -f "$mcpxml" ] && grep -q 'name="enableMcpServer" value="true"' "$mcpxml"; then
  ok "MCP Server enabled (enableMcpServer=true)"
else
  bad "MCP Server NOT enabled → Settings → Tools → MCP Server → tick \"Enable MCP Server\" (or run configure-ide.sh with the IDE closed)"
fi
# brave mode is informational, never a failure
if [ -f "$mcpxml" ] && grep -q 'name="enableBraveMode" value="true"' "$mcpxml"; then
  warn "Brave mode is ON — Claude can run shell/run-configs/SQL unprompted. Off recommended unless intended."
fi

# --- DATABASE ACCESS WARNING: always shown, this is the point of it -----------
# The bundled server exposes execute_sql_query / list_database_connections /
# preview_table_data. Every datasource configured in this IDE — INCLUDING
# production — becomes queryable by Claude. Make the user opt into that knowingly.
printf '\n  \033[1;31m⚠ DATABASE ACCESS\033[0m  This connection lets Claude query EVERY database\n'
printf '     datasource configured in your IDE — including production, if present.\n'
printf '     Tools: execute_sql_query, list_database_connections, preview_table_data.\n'
printf '     Proceed only if that is what you want. To limit exposure: remove/disable\n'
printf '     sensitive datasources in the IDE, or keep Brave mode OFF so each query prompts.\n'

# --- LANGUAGE / TEST SUPPORT: warn only --------------------------------------
# JVM repos here are Java and/or Kotlin. The Java + JUnit + Kotlin plugins are
# all BUNDLED and on by default — they only show up as a problem if someone
# disabled them. Kotest is the only one needing a Marketplace install.
if [ -d "$app/Contents/plugins/java" ] && ! is_disabled "com.intellij.java"; then
  ok "Java plugin enabled (semantic index for .java)"
else
  warn "Java plugin disabled — code intelligence on .java files will be degraded. Settings → Plugins → enable \"Java\""
fi
if [ -d "$app/Contents/plugins/junit" ] && ! is_disabled "JUnit"; then
  ok "JUnit plugin enabled (run/debug Java + Kotlin JUnit tests by line)"
else
  warn "JUnit plugin disabled — no run points for JUnit tests. Settings → Plugins → enable \"JUnit\""
fi
if [ -d "$app/Contents/plugins/Kotlin" ] && ! is_disabled "org.jetbrains.kotlin"; then
  ok "Kotlin plugin enabled (semantic index for .kt)"
else
  warn "Kotlin plugin disabled — code intelligence on .kt files will be degraded. Settings → Plugins → enable \"Kotlin\" (skip if this is a Java-only repo)"
fi
if [ -d "$cfg/plugins/kotest-intellij-plugin" ] && ! is_disabled "kotest-plugin-intellij"; then
  ok "Kotest plugin enabled (run/debug *Spec.kt by line)"
else
  warn "Kotest plugin absent — no run points for *Spec.kt specs (JUnit tests still work). Only needed if you use Kotest. Install via Settings → Plugins → \"Kotest\""
fi

# --- OPTIONAL extras: never a failure, just report the picture -----------------
if [ -d "$app/Contents/plugins/debuggerMcp" ] && ! is_disabled "intellij.debuggerMcp"; then
  ok "debuggerMcp plugin enabled (extra xdebug tool surface)"
else
  info "debuggerMcp plugin off/absent — xdebug_* tools may be reduced (optional)"
fi
# Marketplace #29174 "IDE Index MCP Server" (hechtcarmel) — adds first-class
# find_definition/find_references the bundled server lacks. Detect any installed
# index-mcp plugin dir; absence is fine, just note the gap.
if ls -d "$cfg/plugins/"*[Ii]ndex*[Mm]cp* "$cfg/plugins/"*hecht* 2>/dev/null | grep -q .; then
  ok "Index MCP plugin installed (first-class find_definition/find_references)"
else
  info "No find-references plugin — bundled server has none; falls back to search_symbol/regex. Optional: install Marketplace #29174 \"IDE Index MCP Server\""
fi

# --- ADVISORY: is this workspace open as a project in the IDE? ----------------
# Each Claude session's MCP bridge resolves tools against the project matching its
# launch dir, so this repo SHOULD be open in IDEA — but this is only a WARN, never
# a FAIL: IDEA writes the opened="true" marker to recentProjects.xml lazily (memory
# -> disk on autosave/shutdown), so a freshly-opened project can still read closed.
# The authoritative runtime proof is 04-probe-tools.sh. Resolve the repo from git
# root so it works when run from a subdirectory; override with REPO=.
repo="${REPO:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
recent="$cfg/options/recentProjects.xml"
if [ "${SKIP_OPEN_CHECK:-}" = "1" ]; then
  warn "Workspace-open check skipped (SKIP_OPEN_CHECK=1)"
elif [ ! -f "$recent" ]; then
  warn "recentProjects.xml not found — cannot confirm the repo is open in IDEA"
elif python3 - "$recent" "$repo" "$HOME" <<'PY'
import sys, re
recent, repo, home = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3].rstrip("/")
xml = open(recent, encoding="utf-8").read()
# entry block = <entry key="..."> ... </entry>; project is open iff its
# RecentProjectMetaInfo carries opened="true".
for key, body in re.findall(r'<entry key="([^"]+)">(.*?)</entry>', xml, re.S):
    path = key.replace("$USER_HOME$", home).rstrip("/")
    if path == repo and 'opened="true"' in body:
        sys.exit(0)
sys.exit(1)
PY
then
  ok "Workspace appears open in IDEA: $repo"
else
  warn "Could not confirm this repo is open in IDEA: $repo"
  echo "       IDEA persists the open-marker lazily, so this is often a false alarm right after opening."
  echo "       Authoritative check: 04-probe-tools.sh <stdio-config.json> — get_project_modules should return THIS repo's modules."
  echo "       To open it: idea \"$repo\"  (then wait for indexing)."
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "Preflight FAILED — fix the items above in the IDE, then re-run. Do not wire Claude Code yet."
  exit 1
fi
echo "Preflight passed (static checks) — IDE side is ready."
echo "Next: 02-make-stdio-config.sh → 03-setup-mcp.sh → 04-probe-tools.sh (runtime tool-registration proof)"
