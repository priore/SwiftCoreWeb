# AI Workspace Manifest

This document serves as the comprehensive catalog and metadata repository for all knowledge base documents in this project. It outlines every document, their purpose, dependencies, generation order, status, priority, recommended AI model, and completion criteria.

## Document List

| Document | Purpose | Dependencies | Recommended Generation Order | Status | Priority | Recommended AI Model | Completion Criteria |
|----------|---------|--------------|------------------------------|--------|----------|---------------------|-------------------|
| README.md | Provides an overview of the AI Workspace and its purpose within the project lifecycle. | None | 1 | Done | High | Qwen | Clear project overview and purpose |
| WORKSPACE_MANIFEST.md | Contains the complete list of documents, their purposes, dependencies, and metadata. | None | 2 | Done | High | Qwen | Complete document list with all metadata |
| architecture/PROJECT_CONTEXT.md | Documents the project's context, including its mission, scope, and key characteristics. | WORKSPACE_MANIFEST.md | 3 | Done | High | Qwen | Comprehensive project context and scope |
| architecture/PROJECT_ANALYSIS.md | Analyzes the project's structure, technologies, and design principles. | architecture/PROJECT_CONTEXT.md | 4 | Done | High | Qwen | Detailed project analysis and technical breakdown |
| architecture/ARCHITECTURE.md | Describes the system architecture, including components, interactions, and design patterns. | architecture/PROJECT_ANALYSIS.md | 5 | Done | High | Qwen | Complete system architecture documentation |
| UI_ANALYSIS.md | Documents the framework's actual (minimal) UI surface — the Showcase app — and states explicitly that no design system exists. | architecture/ARCHITECTURE.md | 6 | Done | Medium | Qwen | Accurate description of the real UI surface, no fabricated content |
| product/ROADMAP.md | Outlines actual delivery history reconstructed from the generation prompt's log. | UI_ANALYSIS.md | 7 | Done | High | Qwen | Roadmap entries traceable to a real source |
| product/DECISIONS.md | Records architectural decisions traceable to code comments or the generation prompt. | product/ROADMAP.md | 8 | Done | Medium | Qwen | Every decision traceable to a source |
| product/KNOWN_ISSUES.md | Lists known issues/limitations traceable to code comments or the generation log. | product/DECISIONS.md | 9 | Done | Medium | Qwen | Every issue traceable to a source |
| product/CHANGELOG.md | Tracks the project's actual single-baseline history (no invented version releases). | product/KNOWN_ISSUES.md | 10 | Done | Medium | Qwen | Matches `git log` and the generation prompt's log |
| GLOSSARY.md | Defines key terms actually used in this codebase and Knowledge Base. | product/CHANGELOG.md | 11 | Done | Low | Qwen | Terms match usage in other documents |
| Prompts/ | Contains the original code-generation prompt (`framework_http_server_prompt.md` = implemented design). An earlier discarded design (`app_http_server_prompt.md`, FlyingFox/GRDB) has since been removed from this folder — see [DECISIONS.md](product/DECISIONS.md) for its historical note. | GLOSSARY.md | 12 | Done (pre-existing) | Low | Qwen | N/A — historical source material |

### Removed from this manifest

- `design/DESIGN_SYSTEM.md`, `DESIGN_TOKENS.md`, and `COMPONENT_LIBRARY.md` were removed on 2026-09-24: SwiftCoreWeb is a server framework with no design system, tokens, or component library anywhere in `Sources/` — these documents had no real subject matter and their prior content was generic template text never verified against the code (see [UI_ANALYSIS.md](UI_ANALYSIS.md)). The empty `design/` directory was removed along with them.
- `templates/`, `workflows/`, `reviews/`, `tasks/`, `documentation/` were removed on 2026-09-24: all five stayed empty since the workspace's creation, with no document ever populated or referenced inside them. YAGNI — recreate any of them only when a real document needs to go there, not speculatively.

If a real UI design system, template, workflow, review, or task-tracking need is ever built for a consumer app, document it in that app's own workspace, not here.

## Initial Roadmap (historical — see [product/ROADMAP.md](product/ROADMAP.md) for actual delivery status)

Phase 1
PROJECT_CONTEXT
↓
Phase 2
PROJECT_ANALYSIS
↓
Phase 3
ARCHITECTURE
↓
Phase 4
UI_ANALYSIS
↓
Phase 5
ROADMAP
↓
Phase 6
DECISIONS
↓
...

## Review Checklist

- Completeness
  - [x] All documents listed, including README.md and GLOSSARY.md (previously missing from this manifest)
  - [x] All metadata provided
  - [x] Dependencies properly identified
  - [x] Generation order logical
- Accuracy
  - [x] Document purposes match actual (corrected) content
  - [x] Dependencies are correct
  - [x] Removed entries for documents with no real subject matter
- Consistency
  - [x] Formatting is consistent
  - [x] `Prompts/` (actual casing) used instead of the incorrect `prompts/`
- TODO
  - [ ] Recreate templates/workflows/reviews/tasks/documentation only if a real need arises — do not create speculative content
- Missing information
  - [ ] None at this time
- Open questions
  - [ ] None at this time
- Confidence level
  - [x] 🟢 Confirmed by the code
