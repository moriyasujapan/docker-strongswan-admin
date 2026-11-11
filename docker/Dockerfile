FROM debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      charon-systemd strongswan-swanctl libcharon-extra-plugins libcharon-extauth-plugins \
      libstrongswan-extra-plugins iptables iproute2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY strongswan.conf /etc/strongswan.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
