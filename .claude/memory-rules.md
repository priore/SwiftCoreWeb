# Memory Rules — what NEVER to write

**Never step status/history in memory** (e.g. "Step N completed/implemented (date): here's what was
done"). If the project keeps a plan or roadmap doc, status/history lives exclusively there, updated
immediately after each step is completed/validated — not in `.claude/memory/`.

Memory (local or global) contains only what a plan doc doesn't capture: reusable technical
gotchas, environment details, code patterns, decisions not obvious from the code — never a
changelog of "what was added for step X" (that's already covered by `git log`).

**Why**: duplicating status in two places creates two sources of truth that diverge over time (a
step marked "completed" in memory but later modified/redone differently, with memory never
updated).

**How to apply**: before writing/updating a memory file about a step, check that it doesn't open
with a status summary ("Step N completed/backend ready/..."). If it does, it must be rewritten to
contain only the reusable parts (algorithms, gotchas, non-obvious decisions).
