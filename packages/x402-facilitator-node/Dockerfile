FROM node:22-alpine AS builder
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@10.15.1 --activate
COPY package.json pnpm-lock.yaml ./
# No `|| pnpm install` fallback, and no `2>/dev/null`. That pair meant a lockfile which
# could not be honoured was silently re-resolved, so the pin said one thing and the image
# shipped another -- with the error hidden, there was nothing to notice. A lockfile that
# does not apply is a failure to fix, not a case to route around.
# `pnpm-lock.yaml` is also no longer optional (`*`): with the glob, a missing lockfile made
# COPY a no-op and the build continued unpinned.
RUN pnpm install --frozen-lockfile
COPY tsconfig.json ./
COPY src ./src
RUN pnpm run build

FROM node:22-alpine
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@10.15.1 --activate
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod
COPY --from=builder /app/dist ./dist
EXPOSE 3402
CMD ["node", "dist/index.js"]
