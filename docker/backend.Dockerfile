FROM node:22-alpine AS build

WORKDIR /app

RUN corepack enable

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .
RUN apk add --no-cache curl \
    && curl --fail --silent --show-error \
      https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
      --output /tmp/aws-rds-global-bundle.pem \
    && echo "e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3  /tmp/aws-rds-global-bundle.pem" | sha256sum -c - \
    && pnpm build \
    && pnpm prune --prod

FROM node:22-alpine AS runtime

ENV NODE_ENV=production

WORKDIR /app

COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/migrations ./migrations
COPY --from=build /tmp/aws-rds-global-bundle.pem /etc/ssl/certs/aws-rds-global-bundle.pem

USER node

EXPOSE 5500

CMD ["sh", "-c", "node dist/scripts/migrate.js && node dist/src/main.js"]
