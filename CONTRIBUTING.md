# Contributing

Guide for contributing to the geoffdavis.com website.

## Setup

1. Clone the repo with submodules:

   ```sh
   git clone --recurse-submodules https://github.com/geoffdavis/geoffdavis-website.git
   cd geoffdavis-website
   ```

2. Verify Hugo is installed:

   ```sh
   hugo version
   ```

   You need Hugo extended edition v0.146.7 or later.

3. Install pre-commit hooks:

   ```sh
   brew install pre-commit
   pre-commit install
   ```

   This installs git hooks that run a Hugo build check and markdownlint on every commit.

4. Start the dev server:

   ```sh
   hugo server -D
   ```

## Making Changes

### Content Changes

- Blog posts go in `content/posts/`. Create new posts with `hugo new posts/my-post.md`.
- Top-level pages go in `content/` (e.g., `content/cv.md`).
- New posts are created as drafts by default. Set `draft = false` in the frontmatter when ready.

### Configuration Changes

- Site configuration lives in `hugo.yaml`.
- The PaperMod theme is pinned as a git submodule in `themes/PaperMod/`. To update it, run:

  ```sh
  git submodule update --remote themes/PaperMod
  ```

## Workflow

1. **Create a feature branch** off `dev`:

   ```sh
   git checkout dev
   git pull origin dev
   git checkout -b my-feature
   ```

2. **Make your changes** and verify locally with `hugo server -D`.

3. **Test the Docker build** to catch any build issues:

   ```sh
   docker build -t geoffdavis-website:test .
   ```

4. **Commit** with a clear message describing what and why:

   ```sh
   git add <files>
   git commit -m "feat: add new blog post about topic X"
   ```

   Use conventional commit prefixes where appropriate:
   - `feat:` — new content or functionality
   - `fix:` — bug fixes or corrections
   - `docs:` — documentation changes
   - `chore:` — maintenance tasks

5. **Push and open a pull request** targeting `dev`:

   ```sh
   git push -u origin my-feature
   ```

6. Once merged to `dev`, verify the staging build in GHCR.

## Promoting Content to Production

Content moves from `dev` to `main` in two steps:

1. **Set `draft = false`** in the frontmatter of any posts that are ready for production. Posts with `draft = true` are included in dev builds but excluded from production builds. You can flip the draft flag before or as part of the merge to `main`.

2. **Merge `dev` into `main`**:

   ```sh
   git checkout main
   git pull origin main
   git merge dev
   git push origin main
   ```

This triggers the production CI workflow, which builds a Docker image with `HUGO_DRAFTS=false` — meaning only posts with `draft = false` appear in the final site.

There is no additional approval gate or manual deployment step. The GitHub Actions workflow fires automatically on push to `main`, and the resulting image is published to GHCR ready for deployment.

### Summary

```
feature branch ──► dev (drafts included) ──► main (drafts excluded)
                     │                          │
                     ▼                          ▼
               dev build in GHCR          production build in GHCR
```

The `draft` frontmatter field is the gate that controls what is visible in production. The branch merge is what triggers the build.

## CI/CD

Pushes to `dev` and `main` trigger GitHub Actions workflows that build and push Docker images to GHCR. The `dev` branch includes draft posts; `main` does not.

Check the Actions tab on GitHub to verify your build succeeded after pushing.

## Verifying Your Changes

- **Locally:** `hugo server -D` for live preview with drafts
- **Docker:** `docker build -t test . && docker run -p 8080:80 test` to test the production build
- **CI:** Check the GitHub Actions run after pushing

# Contributing

Guide for contributing to the geoffdavis.com website.

## Setup

1. Clone the repo with submodules:

   ```sh
   git clone --recurse-submodules https://github.com/geoffdavis/geoffdavis-website.git
   cd geoffdavis-website
   ```

2. Verify Hugo is installed:

   ```sh
   hugo version
   ```

   You need Hugo extended edition v0.146.7 or later.

3. Start the dev server:

   ```sh
   hugo server -D
   ```

## Making Changes

### Content Changes

- Blog posts go in `content/posts/`. Create new posts with `hugo new posts/my-post.md`.
- Top-level pages go in `content/` (e.g., `content/cv.md`).
- New posts are created as drafts by default. Set `draft = false` in the frontmatter when ready.

### Configuration Changes

- Site configuration lives in `hugo.yaml`.
- The PaperMod theme is pinned as a git submodule in `themes/PaperMod/`. To update it, run:

  ```sh
  git submodule update --remote themes/PaperMod
  ```

## Workflow

1. **Create a feature branch** off `dev`:

   ```sh
   git checkout dev
   git pull origin dev
   git checkout -b my-feature
   ```

2. **Make your changes** and verify locally with `hugo server -D`.

3. **Test the Docker build** to catch any build issues:

   ```sh
   docker build -t geoffdavis-website:test .
   ```

4. **Commit** with a clear message describing what and why:

   ```sh
   git add <files>
   git commit -m "feat: add new blog post about topic X"
   ```

   Use conventional commit prefixes where appropriate:
   - `feat:` — new content or functionality
   - `fix:` — bug fixes or corrections
   - `docs:` — documentation changes
   - `chore:` — maintenance tasks

5. **Push and open a pull request** targeting `dev`:

   ```sh
   git push -u origin my-feature
   ```

6. Once merged to `dev`, verify the staging build in GHCR. When ready, merge `dev` into `main` for production.

## CI/CD

Pushes to `dev` and `main` trigger GitHub Actions workflows that build and push Docker images to GHCR. The `dev` branch includes draft posts; `main` does not.

Check the Actions tab on GitHub to verify your build succeeded after pushing.

## Verifying Your Changes

- **Locally:** `hugo server -D` for live preview with drafts
- **Docker:** `docker build -t test . && docker run -p 8080:80 test` to test the production build
- **CI:** Check the GitHub Actions run after pushing
