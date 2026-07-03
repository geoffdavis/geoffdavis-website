# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
# Local development with live reload
hugo server -D

# Create a new post
hugo new posts/my-post.md

# Production build
hugo

# Build matching the staging image (drafts rendered)
hugo --buildDrafts

# Test the container build locally
docker build -t geoffdavis-website .
docker run -p 8080:80 geoffdavis-website

# Update the toha theme (Hugo module) and refresh the vendored copy
hugo mod get -u github.com/hugo-toha/toha/v4
hugo mod vendor
```

## Architecture

Hugo static site → Docker (Nginx) → GHCR → Kubernetes (ARM cluster).

**Content:** `content/posts/` for blog posts, `content/` root for pages (e.g. `cv.md`). Frontmatter uses TOML (delimited by `+++`). **`draft = true` is the production gate**: main builds BOTH images — staging renders drafts, production hides them. Publish a post by flipping its draft flag to false (or removing it).

**Theme:** [hugo-toha/toha](https://github.com/hugo-toha/toha) v4, consumed as a Hugo module (declared in `go.mod`, pinned in `hugo.yaml` under `module.imports`) and vendored into `_vendor/`. No git submodule — CI builds straight from the vendored copy. Do not edit theme files directly.

**Build:** Two-stage Dockerfile — `hugomods/hugo:exts-non-root-0.146.7` compiles the site, Nginx Alpine serves it. The `HUGO_DRAFTS` build arg controls `--buildDrafts`.

**CI/CD:** Three GitHub Actions workflows in `.github/workflows/`:

- `lint.yaml` — triggers on pushes to `main`/`dev` and all pull requests; runs markdownlint and Hugo build check
- `publish.yaml` — triggers on `main`, builds with `HUGO_DRAFTS=false` (production), tags `main-{TIMESTAMP}-{SHA}`
- `publish-dev.yaml` — ALSO triggers on `main`, builds with `HUGO_DRAFTS=true` (staging/draft preview), tags `dev-{TIMESTAMP}-{SHA}` (prefix kept for cluster image-automation compatibility)

Both publish workflows push multi-arch images (`linux/amd64`, `linux/arm64`) to `ghcr.io/geoffdavis/geoffdavis-website`.

## Branching and Content Promotion

- Feature branches → PR → `main` (single branch; the old `dev` staging branch is retired)
- New posts land on main with `draft = true` → visible on staging only
- To promote a post to production: flip `draft = false` (or remove the flag) in a follow-up PR

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
