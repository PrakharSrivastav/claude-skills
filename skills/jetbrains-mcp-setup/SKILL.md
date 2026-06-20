---
name: jetbrains-mcp-setup
description: >-
  Connect Claude Code to a running IntelliJ IDEA's bundled MCP server (macOS) so Claude
  works off the IDE's live semantic index instead of grep — real diagnostics, semantic
  rename, symbol info, debugger control, and large token savings. Use when reconfiguring a
  fresh Claude Code install, onboarding a repo to the IDE MCP, or when the JetBrains tools
  "connect but don't show up".
---

# JetBrains IDE MCP setup for Claude Code

Wire Claude Code to the **MCP server bundled in IntelliJ IDEA** (2025.2+, default-on). The
IDE holds the semantic index, so Claude reasons over what the code *means* — and answers
from the index instead of reading files into context (the big token win). Scope: **macOS +
IntelliJ IDEA**. No per-repo residue; opt-out is one `claude mcp remove`.

**Why it matters — tokens.** `Grep`/`Read` load file *contents* into context; the IDE
returns only the *answer*: `rename_refactoring` updates every reference reading **zero**
files; `get_file_problems` returns just diagnostics; `get_symbol_info` returns a signature,
not the file. On a large codebase, the difference is a query fitting in context vs. blowing it.

**Use when:** fresh Claude install · onboarding a repo · diagnosing "connects but no tools".

**Prereqs:** IDE **2025.2+**, **open** on the project with indexing finished (desktop only —
no CI/headless; tools vanish when the IDE closes). `claude` CLI + `python3` on PATH.

**Convention (multi-workspace works):** the repo you run this skill from should be open as a
project in IDEA. Each Claude session's MCP bridge resolves tools against the project matching
its **launch dir**, so two open project windows each get their **own correct index** — verified
with `get_project_modules` (returns that repo's modules). Step 0 only **warns** if it can't
confirm the repo is open: IDEA writes the open marker lazily so it's unreliable, and the
runtime probe (Step 3) is the real proof. Silence the warning with `SKIP_OPEN_CHECK=1`.

## Step 0 — Preflight (run FIRST; it gates everything)
A missing/disabled plugin or unticked setting makes Claude connect but see **zero tools**
(looks like a client bug, is IDE-side). Verify before touching Claude config:

```bash
scripts/01-check-prereqs.sh    # exit 0 = ready; exit 1 = fix the FAIL items in the IDE first
```

**If it FAILs, stop and have the user enable the missing item in the IDE — do not proceed.**

**If it only WARNs "could not confirm repo is open"** (all FAIL-gates green), that may be a
false alarm — IDEA writes the open marker lazily, so a freshly-opened project still reads as
closed. Don't trust the warning either way; the Step 3 probe is authoritative. If the repo
genuinely isn't open, offer to open it instead of making the user do it:
> "This repo isn't open in IDEA. Claude can open it for you — proceed?"

On yes, run the IDE launcher (exit 0 means the launch was *dispatched* — not that the project
finished opening or indexing):
```bash
idea "$PWD"        # opens this repo as a project in IDEA (Toolbox/app-bundle launcher on PATH)
```
Indexing runs asynchronously after open. Do **not** rely on re-running `01` to confirm — the
open marker can stay stale; confirm with the Step 3 probe (`get_project_modules` should return
THIS repo's modules). Do **not** open it without asking — it changes the user's IDE windows.

**Required (FAIL-gate, any language):**

| Requirement | If missing |
|------|------|
| `mcpserver` bundled plugin, **enabled** | IDE < 2025.2 → upgrade; else Settings → Plugins → enable "MCP Server" → restart |
| **Enable MCP Server** (`enableMcpServer=true`) | Settings → Tools → MCP Server → tick it (in the **running** IDE) |

<!-- BUILD NOTE (for a future configure-ide.sh that flips this by writing mcpServer.xml):
     the IDE reads options/*.xml at startup and REWRITES it from memory on shutdown — a live
     edit is ignored this session AND clobbered on quit. Such a script MUST run IDE-closed:
     quit → write xml → start. The manual "tick the box" path above avoids this entirely. -->


**Language/test (WARN — all bundled & on by default except Kotest):**

| Plugin | Needed for | Note |
|------|------|------|
| `Java` (`com.intellij.java`) | index `.java` | bundled |
| `JUnit` (`JUnit`) | run/debug JUnit tests by line (Java **and** Kotlin) | bundled |
| `Kotlin` (`org.jetbrains.kotlin`) | index `.kt` | bundled; skip on Java-only repos |
| `Kotest` (`kotest-plugin-intellij`) | run/debug `*Spec.kt` by line | **Marketplace install**; only if you use Kotest |

Java-only repo → nothing to install. Optional **INFO** checks: `debuggerMcp`, and #29174 (see
Known gap). The checker is static (files only); for runtime/indexing proof use `04-probe-tools.sh`.

> ⚠️ **DATABASE ACCESS.** The server exposes `execute_sql_query`,
> `list_database_connections`, `preview_table_data` — Claude can query **every datasource in
> your IDE, including production**. The preflight prints this every run. Limit exposure:
> remove/disable sensitive datasources, and keep **Brave mode off**.

**Claude MUST relay this to the user — do not just run the script and summarize the result.**
The preflight prints the DATABASE ACCESS warning to stdout, but the user does not read tool
output; they read your message. So you must surface it explicitly: after running the preflight
and **before registering the server (Step 2)**, present the DATABASE ACCESS warning to the user
in your own message and get an explicit acknowledgment. Registering grants Claude query access
to every datasource configured in the IDE, including production. Do not proceed to Step 2
without the user's OK. If Brave mode is ON, call that out in the same message (queries would run
unprompted).

> **Brave mode** (`enableBraveMode`) = Claude runs shell/run-configs/SQL **unprompted**. Not
> required; leave **off**. The checker WARNs if on.

## Step 1 — Get the stdio config (never guess the endpoint)
On 2026.x the HTTP/SSE endpoint is gated; a hand-crafted URL fails. Two ways to get the
authoritative stdio config — try the script, fall back to the manual button:

```bash
scripts/02-make-stdio-config.sh /tmp/ij-mcp.json   # auto: reconstructs the exact command/classpath/env
```
It pins the known-good jar set (one plugin jar + a fixed set of platform libs — **not** a glob)
and **verifies every jar exists**; on any drift (IDE version bump moved/renamed a jar) it FAILs
and points you at the manual path below. Manual is always correct:

> **Fallback / manual:** Settings → **Tools → MCP Server** → **Copy Stdio Config** (not SSE),
> then `pbpaste > /tmp/ij-mcp.json`.

All scripts read that file.

Shape (paths/port are install-specific — never hardcode across machines):
```json
{ "type": "stdio",
  "env": { "IJ_MCP_SERVER_PORT": "64342" },
  "command": "/path/to/IntelliJ IDEA.app/Contents/jbr/Contents/Home/bin/java",
  "args": ["-classpath", "<mcpserver + ktor + kotlinx jars>",
           "com.intellij.mcpserver.stdio.McpStdioRunnerKt"] }
```

## Step 2 — Register with Claude
**Gate:** before running this, you must have surfaced the DATABASE ACCESS warning (Step 0) to
the user in your own message and gotten their OK — registering makes that access live.
```bash
scripts/03-setup-mcp.sh <any-repo-dir> /tmp/ij-mcp.json --user   # user scope: everywhere
scripts/03-setup-mcp.sh /path/to/repo  /tmp/ij-mcp.json          # project scope: this repo
```
Writes `jetbrains-idea` into `~/.claude.json` (user scope, or under `projects["<repo>"]`).
**Nothing is written into the repo tree.** **Idempotent** — re-running replaces the existing
entry cleanly (no "already exists" error). Add **`--dry-run`** to print the exact
remove/add commands without changing anything. `01`/`04` are read-only; `02` only writes the
stdio-config file you name (default `/tmp/ij-mcp.json`), touching no Claude/IDE config.

> **After registering, run `/mcp` to load it into the current session.** Claude reads MCP
> servers at session start, so a newly added server is invisible until you reconnect. `/mcp`
> → "Reconnected to jetbrains-idea" and the tools appear. (Restarting `claude` also works.)
> **Not** `/reload-plugins` — that reloads skills/agents/hooks, *not* user-added MCP servers.

## Step 3 — Verify
```bash
claude mcp list | grep jetbrains-idea      # expect: ✔ Connected (run from the repo dir)
scripts/04-probe-tools.sh /tmp/ij-mcp.json # server-side proof; expect ~49 tools
```
Then confirm it's bound to the **right project** (the bridge resolves by launch dir, and with
multiple IDEA windows open you want to be sure): call `get_project_modules` (no `projectPath`)
— it must return THIS repo's modules. Wrong modules = a different project's window is what this
session resolved against.

- Tools in probe but not in Claude → run `/mcp` to reconnect (restart `claude` if needed).
- Zero in probe → IDE-side: open? MCP enabled? indexing done?
- Right tools, wrong project → confirm this repo is open in IDEA and that the bridge launched
  from this repo dir (local-scope registration handles that).

Probe isolates IDE health from Claude's registration bug
[claude-code#41418](https://github.com/anthropics/claude-code/issues/41418) (connects, zero tools).

## Tool surface (~49)
| Capability | Tool |
|------------|------|
| Diagnostics | `get_file_problems` |
| Semantic rename | `rename_refactoring` |
| Symbol info / search | `get_symbol_info`, `search_symbol`, `search_in_files_by_text` |
| Debugger | `xdebug_*` (session, breakpoints, evaluate, stack) |
| Build/run/test | `build_project`, `execute_run_configuration`, `get_run_configurations` |
| DB | `execute_sql_query`, `list_schema_objects`, … |

**Known gap:** no first-class go-to-definition / find-references (falls back to
`search_symbol`/regex). Add them with Marketplace **#29174 "IDE Index MCP Server"**
(`hechtcarmel/jetbrains-index-mcp-plugin`) → `ide_find_definition`/`ide_find_references`. Optional.

## Make Claude prefer the IDE (optional)
Add to the repo's `CLAUDE.md` so you stop nudging it:
> For code intelligence prefer the `jetbrains-idea` MCP (`get_file_problems`,
> `rename_refactoring`, `get_symbol_info`) over grep/text-edit. The IDE must be open.

## Feedback loop (self-evolve)
Every run of `01`/`02`/`03` appends each **FAIL / WARN / ERR** to `.fieldlog` in this
skill dir (local, append-only, safe to delete; override with `FIELDLOG=`). That turns
one-off setup failures into durable signal instead of losing them when the session ends.

**At the end of a setup run, harvest it — inline, while context is fresh:**
```bash
tail -n 20 ~/.claude/skills/jetbrains-mcp-setup/.fieldlog 2>/dev/null
```
For any FAIL/WARN/ERR mode that this SKILL.md or the scripts **do not already cover** — a
new IDE version, an unhandled launcher/config path, a FAIL with no documented fix, an IDE
config-format drift — **propose the SKILL.md/script edit now**. That is how the skill
improves over time. Modes already documented here are expected noise; skip them.
Periodic backstop: `sdd-skill-health-check` reviews the same log on its cadence.

## Opt-out
```bash
claude mcp remove jetbrains-idea
```

## Gotchas (hard-won)
- **Mid-session add ≠ visible** — run `/mcp` to load a new server (or restart `claude`).
  Not `/reload-plugins` — that's skills/agents/hooks, not user-added MCP servers.
- **Restarting the IDE orphans the bridge** — Claude holds one stdio bridge from session
  start; restarting the IDE kills it and in-session calls then **hang** (not error). Fix:
  `/mcp` reconnect. Tell-tale: `04-probe-tools.sh` still lists tools (fresh bridge) while
  in-session calls hang — that combination *is* the orphaned-bridge signature.
