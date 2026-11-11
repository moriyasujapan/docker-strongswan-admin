# --- フロントエンド (React 19 + Astryx) をビルド ---
FROM node:22-slim AS ui
WORKDIR /ui
COPY admin/frontend/package.json admin/frontend/package-lock.json ./
RUN npm ci
COPY admin/frontend/ ./
RUN npm run build

# --- 管理API (Flask) + 静的配信 ---
FROM debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-flask openssl strongswan-swanctl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY docker/strongswan.conf /etc/strongswan.conf
# swanctl --load-all は /etc/swanctl を読む。マウント先(/app/swanctl)へ向けないとサーバ設定が空で上書きされる
RUN rm -rf /etc/swanctl && ln -s /app/swanctl /etc/swanctl
COPY scripts /app/scripts
COPY admin/app.py /app/app.py
COPY --from=ui /ui/dist /app/static
WORKDIR /app
CMD ["python3", "/app/app.py"]
