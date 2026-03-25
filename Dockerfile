FROM hugomods/hugo:exts-non-root-0.146.7 AS builder
WORKDIR /src

# Install npm dependencies first (layer-cached separately from source)
COPY --chown=hugo:hugo package.json package-lock.json ./
RUN npm ci

# Copy source and build
COPY --chown=hugo:hugo . .
ARG HUGO_DRAFTS=false
RUN if [ "$HUGO_DRAFTS" = "true" ]; then hugo --buildDrafts; else hugo; fi

FROM nginx:alpine
COPY --from=builder /src/public /usr/share/nginx/html
EXPOSE 80
