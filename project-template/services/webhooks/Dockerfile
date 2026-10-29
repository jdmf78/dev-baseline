# syntax=docker/dockerfile:1
FROM node:24-slim

ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000
WORKDIR /app

COPY package.json ./
# Once you add dependencies (and a package-lock.json):
# COPY package-lock.json ./
# RUN npm ci --omit=dev
COPY src ./src

USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/healthz').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]
CMD ["node", "src/server.js"]
