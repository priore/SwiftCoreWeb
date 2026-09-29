# Token-saving rules (portable)

Most tokens are cache reads of context, not agent output: guard what the agent reads.

1. **Search first, read only the needed lines.** Never re-read unchanged files. Use `grep`, file-specific line offsets, and targeted read windows to minimize context load.

2. **Run the narrowest tests first.** Full suite only at the end:
   - C#: `dotnet test --filter "Namespace.ClassName.MethodName"`
   - JavaScript/Jest: `jest -t "test name"` or `-t "describe block"`
   - Python/pytest: `pytest -k "test_function_name"`
   - Go: `go test -run "TestName"`

3. **Wait inside one command, never repeated sleep-and-check calls.** Use `gh run watch`, `until` loops, or equivalent blocking operations instead of polling.

4. **Inspect UI through the accessibility tree; screenshots only for visual verification.**
   - iOS Simulator: `idb ui describe-all --udid <udid>` (accessibility tree, cheap)
   - Android: `adb shell uiautomator dump` (accessibility tree XML)
   - Web: Playwright `browser_snapshot` (accessibility tree + DOM structure)
   - Screenshots: use only for colors, layout, dark-mode verification

5. **Build/test output goes through the project's build filter** (enforced by `.claude/settings.json` hook).
   - C#: `dotnet build -v q -clp:ErrorsOnly`, `dotnet test --logger "console;verbosity=minimal"`
   - JavaScript: `jest --silent`, `tsc --pretty false`
   - Python: `pytest -q --tb=short`
   - Never paste raw build logs or full test output

6. **Keep one skill per framework; remove duplicates.** Reuse across projects.

7. **Delegate self-contained searches to a subagent** (Explore/Haiku); keep the main model for decisions and edits.

8. **Before adding code: check codebase, stdlib, framework.** Minimal working change only.

9. **Lead with results.** No plan restatement, no tool narration.

10. **Stop after two failed attempts: report findings** instead of looping.

11. **Keep CLAUDE.md small.** Move area-specific or rarely needed docs to separate files and link them.

12. **Suggest a new chat for unrelated tasks.** Context-switch is cheaper than bloat.
