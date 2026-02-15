# ---- Stage 1: VM root filesystem ----
FROM --platform=linux/arm64 alpine:3.20 AS vm

RUN apk add --no-cache \
    alpine-base openrc docker docker-cli-compose \
    socat linux-lts e2fsprogs

COPY rootfs/ /

RUN chmod +x /usr/local/bin/vm-agent*.sh \
    /etc/init.d/vm-agent \
    /etc/init.d/apppod-compose /etc/init.d/data-disk && \
    rc-update add networking default && \
    rc-update add docker default && \
    rc-update add vm-agent default && \
    rc-update add apppod-compose default && \
    rc-update add data-disk default && \
    mkdir -p /data

# ---- Stage 2: ext4 image builder ----
FROM --platform=linux/arm64 alpine:3.20

RUN apk add --no-cache e2fsprogs lz4 rsync

COPY --from=vm / /vm-rootfs/
COPY build-image.sh /build-image.sh
RUN chmod +x /build-image.sh

ENTRYPOINT ["/build-image.sh"]
