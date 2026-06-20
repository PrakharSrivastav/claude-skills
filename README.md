# claude-skills

A collection of [Claude Code](https://claude.com/claude-code) skills.

## Skills

| Skill | Platform | Description |
|-------|----------|-------------|
| [`jetbrains-mcp-setup`](skills/jetbrains-mcp-setup/) | macOS | Wire Claude Code to the MCP server bundled in IntelliJ IDEA, so Claude works off the IDE's live semantic index instead of grepping and reading files — real diagnostics, semantic rename, symbol lookup, debugger control, and a much lighter token bill. See the [skill README](skills/jetbrains-mcp-setup/README.md) for setup and platform notes. |

Each skill lives under `skills/<name>/` with its own `README.md`. The `SKILL.md` in each
directory is the machine-facing manifest Claude loads; the `README.md` is for humans.
