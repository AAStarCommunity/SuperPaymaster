FROM node:22-alpine AS builder
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@latest --activate
COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile 2>/dev/null || pnpm install
COPY tsconfig.json ./
COPY src ./src
RUN pnpm run build

FROM node:22-alpine
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@latest --activate
COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile --prod 2>/dev/null || pnpm install --prod
COPY --from=builder /app/dist ./dist
EXPOSE 3402
CMD ["node", "dist/index.js"]
