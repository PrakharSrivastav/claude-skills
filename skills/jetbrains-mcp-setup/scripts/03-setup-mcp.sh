#!/usr/bin/env bash
# Register the JetBrains IDE bundled MCP server with Claude Code.
#
# Usage:
#   03-setup-mcp.sh <repo-dir> <stdio-config.json> [--user] [--dry-run]
#
#   <repo-dir>           Repo to enable it for (local scope keys off this path).
#   <stdio-config.json>  File holding the JSON from the IDE:
#                        Settings -> Tools -> MCP Server -> "Copy Stdio Config".
#   --user               Register at user scope (every project) instead of local (this repo).
#   --dry-run            Print what would happen; make NO changes.
#
# Idempotent: re-running re-registers cleanly (removes any existing entry of the same
# name+scope first, then adds), so repeated runs converge to the same state instead of
# erroring on "already exists". Nothing is written into the repo tree (entry lives in
# ~/.claude.json).
set -euo pipefail

# Field log: record unexpected failures so real setups feed back into the skill
# (harvested at end of run — see SKILL.md "Feedback loop"). Local, append-only.
FIELDLOG="${FIELDLOG:-$(cd "$(dirname "$0")/.." && pwd)/.fieldlog}"
logf() { printf '%s\t03\t%s\t%s\n' "$(date +%FT%T)" "$1" "$2" >>"$FIELDLOG" 2>/dev/null || true; }
trap 'logf ERR "line $LINENO: $BASH_COMMAND"' ERR

NAME="jetbrains-idea"
DRY=0; scope="local"; pos=()
for a in "$@"; do
  case "$a" in
    --user)    scope="user" ;;
    --dry-run) DRY=1 ;;
    -*)        echo "unknown flag: $a" >&2; exit 2 ;;
    *)         pos+=("$a") ;;
  esac
done
repo="${pos[0]:?usage: 03-setup-mcp.sh <repo-dir> <stdio-config.json> [--user] [--dry-run]}"
cfg="${pos[1]:?stdio config json file required (Copy Stdio Config from the IDE)}"

[ -d "$repo" ] || { echo "repo dir not found: $repo" >&2; exit 1; }
[ -f "$cfg" ]  || { echo "config json not found: $cfg" >&2; exit 1; }
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$cfg" \
  || { logf FAIL "invalid JSON in stdio config $cfg (IDE Copy-Stdio-Config format drift?)"; echo "invalid JSON in $cfg" >&2; exit 1; }
json="$(cat "$cfg")"

# Does an entry already exist for this scope? `claude mcp get` is read-only.
exists=0
if ( cd "$repo" && claude mcp get "$NAME" >/dev/null 2>&1 ); then exists=1; fi

run() {  # echo + (execute unless dry-run). Quote-safe for logging.
  if [ "$DRY" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}

if [ "$DRY" = 1 ]; then echo "DRY RUN — no changes will be made"; fi
[ "$exists" = 1 ] && state="present (will be replaced)" || state="absent (will be added)"
echo "Target: name=$NAME scope=$scope repo=$repo — currently $state"

# add-json --scope local keys off the cwd, so all ops run from the repo dir.
if [ "$exists" = 1 ]; then
  run sh -c "cd '$repo' && claude mcp remove '$NAME' --scope '$scope'"
fi
run sh -c "cd '$repo' && claude mcp add-json --scope '$scope' '$NAME' '$json'"

if [ "$DRY" = 1 ]; then
  echo "DRY RUN complete — re-run without --dry-run to apply."
  exit 0
fi
echo "Registered '$NAME' (scope=$scope) for: $repo"
echo "NEXT: run /mcp (or restart 'claude') in that repo so the tools load."
echo "      The IDE must be open and finished indexing."
