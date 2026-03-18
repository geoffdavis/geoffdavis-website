FROM klakegg/hugo:ext-alpine AS builder
WORKDIR /src
COPY . .
ARG HUGO_DRAFTS=false
RUN if [ "$HUGO_DRAFTS" = "true" ]; then hugo --buildDrafts; else hugo; fi

FROM nginx:alpine
COPY --from=builder /src/public /usr/share/nginx/html
EXPOSE 80
