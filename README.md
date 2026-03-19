# geoffdavis.com

Personal website built with [Hugo](https://gohugo.io/) and the [PaperMod](https://github.com/adityatelange/hugo-PaperMod) theme, served via Nginx in a Docker container.

## Prerequisites

- [Hugo](https://gohugo.io/installation/) (extended edition, v0.146.7+)
- [Docker](https://docs.docker.com/get-docker/) (for container builds)
- Git (with submodule support)

## Getting Started

Clone the repository with the theme submodule:

```sh
git clone --recurse-submodules https://github.com/geoffdavis/geoffdavis-website.git
cd geoffdavis-website
```

If you already cloned without `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

## Local Development

Start the Hugo development server with live reload:

```sh
hugo server -D
```

The site will be available at `http://localhost:1313/`.

## Creating Content

Create a new post:

```sh
hugo new posts/my-new-post.md
```

This generates a file from the archetype template. The branch is the gate — posts on `dev` are staging, posts on `main` are production. Do not use the `draft` frontmatter field.

## Docker

Build and run the site locally in a container:

```sh
docker build -t geoffdavis-website .
docker run -p 8080:80 geoffdavis-website
```

## Branching Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Production |
| `dev` | Staging / preview |

<<<<<<< HEAD
Feature branches are merged into `dev` for preview, then into `main` for production. The `draft` frontmatter field controls visibility: posts with `draft = true` appear in dev builds but are excluded from production. See [CONTRIBUTING.md](CONTRIBUTING.md#promoting-content-to-production) for the full promotion workflow.
=======
Feature branches are merged into `dev` for preview, then into `main` for production.
>>>>>>> b663601 (docs: add README and CONTRIBUTING guide)

## CI/CD

GitHub Actions workflows automatically build and push multi-arch Docker images (`linux/amd64`, `linux/arm64`) to GHCR on pushes to `main` and `dev`:

- **`main`** pushes produce images tagged `main-{TIMESTAMP}-{SHA}` (production).
- **`dev`** pushes produce images tagged `dev-{TIMESTAMP}-{SHA}` (staging).

Images are published to `ghcr.io/geoffdavis/geoffdavis-website`.

## Project Structure

```
.
├── archetypes/          # Content templates
├── content/             # Site content (posts, pages)
│   └── posts/           # Blog posts
├── themes/PaperMod/     # Theme (git submodule)
├── .github/workflows/   # CI/CD pipelines
├── Dockerfile           # Multi-stage container build
└── hugo.yaml            # Hugo configuration
```

## License

All rights reserved unless otherwise specified.
