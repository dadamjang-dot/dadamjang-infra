FROM node:22-alpine AS build

WORKDIR /app

RUN corepack enable

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .
RUN pnpm build && \
    pnpm exec tsc scripts/migrate.ts --outDir dist/scripts --module commonjs --target es2021 --esModuleInterop true && \
    pnpm prune --prod

FROM node:22-alpine AS runtime

ENV NODE_ENV=production

WORKDIR /app

COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/migrations ./migrations

USER node

EXPOSE 5500

CMD ["sh", "-c", "node dist/scripts/migrate.js && node dist/main"]
