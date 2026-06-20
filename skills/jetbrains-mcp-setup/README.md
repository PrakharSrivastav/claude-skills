# jetbrains-mcp-setup

Wire Claude Code to the **MCP server bundled in IntelliJ IDEA** so Claude reasons over your
project's live semantic index instead of grepping and reading files.

## Why

Most AI coding agents answer questions about your code by reading files into context. "Where is
this used?" pulls in whole files; "rename this" reads, edits, and reads again across the repo.
On a large codebase a single question can burn thousands of tokens and crowd out the context you
actually need to reason.

The IDE already holds the answer. IntelliJ keeps a live, semantic index of your project, so
Claude can ask it directly and get back the *answer* instead of the haystack:

- `rename_refactoring` updates every reference while reading **zero** files
- `get_file_problems` returns the diagnostics, not the file
- `get_symbol_info` returns a signature, not the surrounding class

Same result, a fraction of the tokens.

## What it does

The skill runs the whole setup end to end:

1. **Preflight** (`scripts/01-check-prereqs.sh`) — a gate that checks the IDE side (MCP plugin
   enabled, setting ticked, language plugins, workspace open) before touching Claude config.
2. **Config** (`scripts/02-make-stdio-config.sh`) — generates the stdio connection config
   automatically, with a manual "Copy Stdio Config" fallback if the IDE layout has drifted.
3. **Register** (`scripts/03-setup-mcp.sh`) — registers the server with Claude Code (user or
   project scope). Idempotent.
4. **Verify** (`scripts/04-probe-tools.sh`) — a runtime probe that proves the tools actually
   loaded, independent of Claude's own registration state.

See [`SKILL.md`](SKILL.md) for the full step-by-step that Claude follows.

## Requirements

- IntelliJ IDEA **2025.2+**, open on the project with indexing finished (desktop only — the
  tools vanish when the IDE closes).
- `claude` CLI and `python3` on your `PATH`.

## Platform

Currently **macOS-only**, but that scoping is a convenience, not a hard limit. The
platform-specific parts are just the IDE install layout, the config directory location, and the
launcher detection — porting to **Linux** (or Windows/WSL) is mostly a matter of adjusting those
paths and the IDE-locator logic; the overall flow stays the same.

The same principles also apply to **any IDE that exposes an MCP server or a semantic index**, not
just IntelliJ IDEA. If your editor can answer structural questions about your code (find
references, rename, diagnostics, symbol info) over a protocol Claude can reach, you can wire it up
the same way and get the same token savings. IntelliJ is simply the first concrete target here.

Contributions that port this to other platforms or IDEs are welcome.

## Security note

The bundled server also exposes database tools (`execute_sql_query`,
`list_database_connections`, `preview_table_data`) — Claude can query **every datasource
configured in your IDE, including production**. The preflight calls this out, and the skill
requires acknowledgment before registering. Limit exposure by removing/disabling sensitive
datasources and keeping IntelliJ's "Brave mode" off.
