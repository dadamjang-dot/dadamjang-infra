FROM node:22-alpine@sha256:76789712cd1ae89a1225eac9077010d68987a423588042dac30446f502f1858c AS build

WORKDIR /app

RUN corepack enable

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .
RUN node --input-type=module -e 'import { writeFileSync } from "node:fs"; const response = await fetch("https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"); if (!response.ok) throw new Error(`AWS RDS CA download failed: ${response.status}`); writeFileSync("/tmp/aws-rds-global-bundle.pem", Buffer.from(await response.arrayBuffer()));'
RUN echo "e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3  /tmp/aws-rds-global-bundle.pem" | sha256sum -c -
RUN pnpm build && pnpm prune --prod

FROM node:22-alpine@sha256:76789712cd1ae89a1225eac9077010d68987a423588042dac30446f502f1858c AS runtime

ENV NODE_ENV=production

WORKDIR /app

COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/migrations ./migrations
COPY --from=build /tmp/aws-rds-global-bundle.pem /etc/ssl/certs/aws-rds-global-bundle.pem

USER node

EXPOSE 5500

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD ["node", "--input-type=module", "-e", "const response = await fetch('http://127.0.0.1:5500/health/ready'); if (!response.ok) process.exit(1)"]

CMD ["sh", "-c", "node dist/scripts/migrate.js && node dist/src/main.js"]
