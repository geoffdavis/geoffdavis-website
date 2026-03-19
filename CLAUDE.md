# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
# Local development with live reload and drafts visible
hugo server -D

# Create a new post
hugo new posts/my-post.md

# Production build (no drafts)
hugo

# Build with drafts (matches dev branch CI behavior)
hugo --buildDrafts

# Test the container build locally
docker build -t geoffdavis-website .
docker run -p 8080:80 geoffdavis-website

# Update PaperMod theme submodule
git submodule update --remote themes/PaperMod
```

## Architecture

Hugo static site → Docker (Nginx) → GHCR → Kubernetes (ARM cluster).

**Content:** `content/posts/` for blog posts, `content/` root for pages (e.g. `cv.md`). Frontmatter uses TOML (delimited by `+++`). New posts default to `draft = true`.

**Theme:** PaperMod is a git submodule at `themes/PaperMod/`. CI checks it out with `submodules: true`. Do not edit theme files directly.

**Build:** Two-stage Dockerfile — `hugomods/hugo:exts-non-root-0.146.7` compiles the site, Nginx Alpine serves it. The `HUGO_DRAFTS` build arg controls `--buildDrafts`.

**CI/CD:** Two GitHub Actions workflows in `.github/workflows/`:
- `publish.yaml` — triggers on `main`, builds with `HUGO_DRAFTS=false`, tags `main-{TIMESTAMP}-{SHA}`
- `publish-dev.yaml` — triggers on `dev`, builds with `HUGO_DRAFTS=true`, tags `dev-{TIMESTAMP}-{SHA}`

Both push multi-arch images (`linux/amd64`, `linux/arm64`) to `ghcr.io/geoffdavis/geoffdavis-website`.

## Branching and Content Promotion

- Feature branches → merge into `dev` (staging, drafts included)
- `dev` → merge into `main` (production, drafts excluded)

To promote a post to production: set `draft = false` in its frontmatter, then merge `dev` into `main`. The CI build is the only gate — there are no tests or linters.

## Pre-commit Hooks

Install once after cloning:

```sh
brew install pre-commit
pre-commit install
```

Hooks run automatically on `git commit`:
- **Hugo build check** — builds with `--buildDrafts`, fails if the site doesn't compile
- **markdownlint** — lints `content/` files (config in `.markdownlint.yaml`)

Run manually against all files: `pre-commit run --all-files`

## Commit Style

Use conventional commit prefixes: `feat:`, `fix:`, `docs:`, `chore:`.
