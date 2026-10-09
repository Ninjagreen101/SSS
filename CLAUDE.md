# The Spire: working agreement

A Roblox RPG built as a Rojo project in strict Luau. Read `README.md` for the
layout and `src/ServerStorage/DESIGN_DECISIONS.md` for past decisions. Each
phase report lives in `docs/`.

## Roles and models

The main session is the **orchestrator**: Fable 5.1 at **high** effort
(drop to medium for routine sessions). It plans phases, makes design and
architecture decisions, writes briefs, accepts or rejects work, and commits.
It does small edits itself.

Subagents can't start subagents, so the orchestrator dispatches every agent
directly:

| Agent | Model / effort | Use for |
|---|---|---|
| `builder` | Opus 5.5 / high | New systems and generators, multi-file features, hard debugging. Raise to **xhigh** in the brief only for netcode, anti-exploit or save-data work. |
| `content-author` | Sonnet 5.5 / medium | Specced single-area work: floor/zone data, Strings, item and loot tables, Config tables, kit pieces, docs. |
| `reviewer` | Sonnet 5.5 / medium | Read-only review of a diff before commit. |
| `checker` | Haiku 5.5 / low | Runs the checks below and reports pass/fail with the exact errors. Never edits. |
| `scout` | Haiku 5.5 / low | Read-only lookups: "where is X", "what touches Y", summarizing long files or logs. |

## Routing rules (keep usage low)

1. **Don't delegate small jobs.** Anything under roughly 30 lines, or that
   needs the context the orchestrator already has, gets done inline. Every
   subagent starts cold and re-reads files.
2. **Reading-heavy, answer-light jobs go to `scout`;** command runs go to
   `checker`. The orchestrator doesn't read many files or long logs itself.
3. **Write a brief for `builder` and `content-author`:** goal, files to touch,
   contracts not to change, and how to verify. A vague brief wastes an Opus run.
4. **Escalate one step at a time:** Haiku → Sonnet → Opus, after one failed
   attempt. Anything that changes architecture or a shared contract
   (`Shared/Types`, `Shared/Net`, Config keys) comes back to the orchestrator.
5. **Normal loop:** brief → `builder` or `content-author` → `checker` →
   `reviewer` (only for non-trivial diffs) → the orchestrator decides and
   commits.
6. **Run independent agents in parallel**, for example `scout` lookups while
   `builder` works on an unrelated area. Never run two agents that edit the
   same files.
7. **Agents report in about 150 words or fewer,** with file paths, results
   and exact errors. Don't paste whole files back into the main session.

## Project rules

- Every script starts with `--!strict`. Functions are typed. Use
  `task.wait/spawn/delay`. No TODOs in shipped code.
- Balance numbers live in `Shared/Config`; player text lives in
  `Shared/Strings`. All names are original.
- The server is the authority. Clients send intent only, through
  `Shared/Net`, which validates and rate-limits every remote.
- World planners (`ServerStorage/WorldBuilder/Plan`) stay pure Luau with no
  Roblox types. A floor's budget is about 40,000 instances.

## Checks

Tools are pinned in `rokit.toml` (rojo, luau-lsp, lune). Cloud containers
start fresh, so if a tool is missing, install it with `rokit install`. The
Roblox type definitions come from
`https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau`.

```bash
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform roblox --sourcemap sourcemap.json \
  --definitions @roblox=globalTypes.d.luau $(find src -name "*.lua")      # expect no output
rojo build default.project.json -o build/TheSpire.rbxl
python3 tools/harness/run_luau.py tools/harness/entries/floor.luau Lowharbor plan > build/floor.json
lune run tools/lune/build_world.luau build/TheSpire.rbxl build/Lowharbor_world.rbxl Lowharbor
```

The harness needs the `luau` CLI (set `LUAU_BIN` if it isn't at the default
path). Blender previews (`tools/blender/*.py`) are optional and expensive.
Run them only when the orchestrator asks to see the world.
