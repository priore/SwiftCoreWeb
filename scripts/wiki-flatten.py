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

A link that escapes docs/ entirely (../README.md, ../.claude/...) can't be
flattened — there's nothing in this repo's docs/ tree to point at. The wiki
is also a separate git repo with no ".." above it worth anything, so a
relative link there 404s (verified against the live wiki: `../README.md`
resolved to github.com/<repo>/README.md, not .../blob/master/README.md).
Those links are rewritten to an absolute GitHub blob URL instead, only in
the wiki copy — the docs/ source keeps its normal relative link, which
works fine for local viewing and for GitHub's own file browser.

Images (![alt](../screenshots/x.png)) are never copied into the wiki repo
either, so any relative image path — inside docs/ or escaping it — is
rewritten to an absolute raw.githubusercontent.com URL the same way.

Usage: wiki-flatten.py <docs-dir> <wiki-dir> [--github-repo-url URL]
"""
import os
import re
import sys

DEFAULT_GITHUB_REPO_URL = "https://github.com/priore/SwiftCoreWeb"

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
    "web/LIVE_PAGES_GUIDE.md": "Web-Live-Pages-Guide",
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


def rewrite_links(text: str, src_dir: str, github_repo_url: str) -> str:
    """Rewrites every [text](relative/path#anchor) link and ![alt](relative/path)
    image in `text`, where `src_dir` is the source file's own directory
    relative to docs/."""

    def rewrite(m: re.Match) -> str:
        bang, label, target = m.group(1), m.group(2), m.group(3)
        if re.match(r"^[a-z]+://", target) or target.startswith("/"):
            return m.group(0)
        path, _, anchor = target.partition("#")
        if not path:
            # Same-page anchor (#section) — nothing to flatten or rewrite.
            return m.group(0)
        resolved = os.path.normpath(os.path.join(src_dir, path))
        is_page_link = path.endswith(".md") and not bang
        if is_page_link and not resolved.startswith(".."):
            new_target = flatten_page_name(resolved) + (("#" + anchor) if anchor else "")
            return f"[{label}]({new_target})"
        # A non-.md asset (image) or a link that escapes docs/ entirely
        # (../README.md, ../.claude/...) can't be flattened — there's nothing
        # in this repo's docs/ tree to point at, and images aren't copied into
        # the wiki repo at all. Rewrite to an absolute GitHub raw/blob URL,
        # since the wiki is a separate git repo where a relative ".." link
        # 404s (verified against the live wiki: `../README.md` resolved to
        # github.com/<repo>/README.md, not .../blob/master/README.md).
        repo_relative = os.path.normpath(os.path.join("docs", src_dir, path))
        kind = "raw" if bang else "blob"
        absolute = f"{github_repo_url}/{kind}/master/{repo_relative}"
        if anchor:
            absolute += f"#{anchor}"
        return f"{bang}[{label}]({absolute})"

    return re.sub(r"(!?)\[([^\]]*)\]\(([^)]+)\)", rewrite, text)


def main() -> None:
    docs_dir, wiki_dir = sys.argv[1], sys.argv[2]
    github_repo_url = DEFAULT_GITHUB_REPO_URL
    if len(sys.argv) > 3 and sys.argv[3] == "--github-repo-url":
        github_repo_url = sys.argv[4]

    for root, _, files in os.walk(docs_dir):
        for name in files:
            if not name.endswith(".md"):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, docs_dir)
            src_dir = os.path.dirname(rel)
            with open(full, encoding="utf-8") as f:
                text = f.read()
            text = rewrite_links(text, src_dir, github_repo_url)
            out_path = os.path.join(wiki_dir, flatten(rel))
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(text)


if __name__ == "__main__":
    main()
