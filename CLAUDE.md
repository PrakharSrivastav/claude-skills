# Claude Code Project Context: claude-skills

A collection of [Claude Code](https://claude.com/claude-code) skills. Each skill is
self-contained under `skills/<name>/` and is independently usable.

## Repository layout

```
claude-skills/
├── README.md                     # collection index (the skills table) — humans
├── CLAUDE.md                     # this file — conventions for working in the repo
└── skills/
    └── <skill-name>/
        ├── SKILL.md              # machine-facing manifest Claude loads (REQUIRED)
        ├── README.md             # human-facing docs for this skill (REQUIRED)
        └── scripts/              # optional helper scripts, numbered by lifecycle
```

## Documentation convention

There are two doc surfaces, with distinct audiences. Keep them in sync but do not duplicate.

### `SKILL.md` (per skill, required)
The **machine-facing manifest** — the only file Claude treats specially. Starts with YAML
frontmatter (`name`, `description`). Contains the step-by-step procedure Claude follows.
Write it as instructions to Claude, not prose for a reader.

### Root `README.md` (the index)
A **slim index** of the collection. Its core is one table, one row per skill:

| Skill | Platform | Description |
|-------|----------|-------------|
| [`<name>`](skills/<name>/) | <macOS / Linux / cross-platform> | One- to two-sentence summary. Link to the per-skill README for detail. |

Keep the root README short — the table plus a line on the layout convention. Per-skill detail
does **not** belong here.

### Per-skill `README.md` (required)
The **human-facing docs** for one skill. Recommended sections:

- **Why** — the problem it solves.
- **What it does** — the flow / scripts, at a glance.
- **Requirements** — prerequisites.
- **Platform** — which OS/tools it is scoped to, and how portable it is. Platform notes live
  **here, per skill** — never as a global statement, because skills differ.
- **Security note** — if the skill grants any sensitive access, call it out explicitly.

## Adding a new skill

1. Create `skills/<name>/` with `SKILL.md` (manifest) and `README.md` (human docs).
2. Put helper scripts under `skills/<name>/scripts/`, numbered by call order
   (`01-...`, `02-...`) so the prefix reflects the lifecycle.
3. Add one row to the table in the root `README.md`.
4. Keep platform/security caveats in the per-skill README, not the root.

## Conventions

- **Scripts**: prefix-number by lifecycle order; keep them idempotent and offer a `--dry-run`
  or read-only mode where it makes sense. Make scripts executable (`chmod +x`).
- **Security warnings the user must see**: a warning printed only to script stdout is invisible
  to the user, because Claude summarizes tool output. If a step grants sensitive access, the
  `SKILL.md` must **direct Claude to relay the warning to the user and get acknowledgment** —
  do not rely on the script's own output.
- **No machine-specific values committed**: paths, ports, and install locations are resolved at
  runtime, never hardcoded across machines.
