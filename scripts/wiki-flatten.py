#!/usr/bin/env python3
"""Copies docs/*.md into a GitHub Wiki checkout (flat layout), rewriting
relative markdown links so they still resolve after flattening.

GitHub Wiki has no real subfolders: every page lives at the wiki root, so
docs/web/EXAMPLES_BASIC.md needs a flat name (e.g. Web-Basic-Examples).
Without rewriting, a link like [Basic examples](web/EXAMPLES_BASIC.md)
resolves on the wiki as "create a new page in a subfolder", not the
actual flattened page.

The wiki's own page router also wants links to *page names*, not
filenames: [text](Web-Basic-Examples) works, [text](Web-Basic-Examples.md)
does not (GitHub serves that as a request for the raw file under the
current page instead of routing to the page) — so the rewritten link
target drops the .md extension entirely.

The flat name also becomes the page's slug, which GitHub shows verbatim
as that page's own header/tab title (separate from — and in addition to
— the file's own first-line `# ` heading) — so PAGE_NAMES below is a
human-readable "Word-Word-Word" name, not a mechanical path-to-dashes
conversion, for every file this wiki ships.

Usage: wiki-flatten.py <docs-dir> <wiki-dir>
"""
import os
import re
import sys

# docs/-relative path -> wiki page name (no .md, no directories — this is
# the flat name GitHub Wiki shows as both filename and page header/title).
# Keep in sync with docs/ whenever a file is added, renamed, or moved.
PAGE_NAMES = {
    "README.md": "Home",
    "GETTING_STARTED.md": "Getting-Started",
    "ROUTING_AND_MIDDLEWARE.md": "Routing-and-Middleware",
    "SECRETS_AND_CERTIFICATES.md": "Secrets-and-Certificates",
    "TESTING_GUIDE.md": "Testing-Guide",
    "FAQ_AND_TROUBLESHOOTING.md": "FAQ-and-Troubleshooting",
    "DOTNET_MAPPING.md": "Dotnet-Naming-Table",
    "web/GETTING_STARTED.md": "Web-Getting-Started",
    "web/EXAMPLES_BASIC.md": "Web-Basic-Examples",
    "web/EXAMPLES_ADVANCED.md": "Web-Advanced-Examples",
    "web/AUTH_AND_SECURITY.md": "Web-Auth-and-Security",
    "web/DASHBOARD_GUIDE.md": "Web-Dashboard-Guide",
    "api/GETTING_STARTED.md": "API-Getting-Started",
    "api/EXAMPLES_BASIC.md": "API-Basic-Examples",
    "api/EXAMPLES_ADVANCED.md": "API-Advanced-Examples",
    "api/AUTH_AND_SECURITY.md": "API-Auth-and-Security",
}


def flatten(rel_path: str) -> str:
    """docs/-relative path -> wiki filename (PAGE_NAMES[...] + .md)."""
    if rel_path not in PAGE_NAMES:
        raise KeyError(
            f"{rel_path} has no entry in PAGE_NAMES (scripts/wiki-flatten.py) — "
            "add one so this file gets a human-readable wiki page name."
        )
    return PAGE_NAMES[rel_path] + ".md"


def flatten_page_name(rel_path: str) -> str:
    """docs/-relative path -> wiki page name for use inside a link (no .md:
    the wiki's router wants page names, not filenames — see module docstring)."""
    return PAGE_NAMES.get(rel_path, flatten(rel_path)[:-3])


def rewrite_links(text: str, src_dir: str) -> str:
    """Rewrites every [text](relative/path.md#anchor) link in `text`, where
    `src_dir` is the source file's own directory relative to docs/."""

    def rewrite(m: re.Match) -> str:
        label, target = m.group(1), m.group(2)
        if re.match(r"^[a-z]+://", target) or target.startswith("/"):
            return m.group(0)
        path, _, anchor = target.partition("#")
        if not path.endswith(".md"):
            return m.group(0)
        resolved = os.path.normpath(os.path.join(src_dir, path))
        if resolved.startswith(".."):
            # Escapes docs/ entirely (../README.md, ../.claude/...) — left as-is,
            # the caller is responsible for those being absolute URLs already.
            return m.group(0)
        new_target = flatten_page_name(resolved) + (("#" + anchor) if anchor else "")
        return f"[{label}]({new_target})"

    return re.sub(r"\[([^\]]*)\]\(([^)]+\.md[^)]*)\)", rewrite, text)


def main() -> None:
    docs_dir, wiki_dir = sys.argv[1], sys.argv[2]
    for root, _, files in os.walk(docs_dir):
        for name in files:
            if not name.endswith(".md"):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, docs_dir)
            src_dir = os.path.dirname(rel)
            with open(full, encoding="utf-8") as f:
                text = f.read()
            text = rewrite_links(text, src_dir)
            out_path = os.path.join(wiki_dir, flatten(rel))
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(text)


if __name__ == "__main__":
    main()
