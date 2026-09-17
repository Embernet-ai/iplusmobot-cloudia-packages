# syntax=docker/dockerfile:1.7
#
# EmberNET IPLUSMOBOT Cloudia (AMR monitor and dispatch server), containerized.
#
# Wraps the vendor's own server install, the same artifacts their
# cloudia-init.sh / install_cloudia.sh / dpkg steps put on an Ubuntu 20.04 box,
# with the vendor files pulled from this repo's GitHub Release rather than
# committed. x86-64 only: the vendor ships nothing else.
#
# What is NOT in here, on purpose:
#   * MySQL, Redis, InfluxDB. The vendor configs point every one of them at
#     127.0.0.1, so they run as sidecars in the same pod (shared localhost) from
#     pinned upstream images. The vendor's jzcloudia-tools bundle (MySQL 5.7.21
#     debs for Ubuntu 16.04, Redis 3.0.6, InfluxDB 1.6.3) is not used.
#   * etcd. install_tools.sh installs it, but no Cloudia binary references it.
#     Checked by grepping cloudserver_v2, cloudweb, apiserver, cloudia and rcsctl.
#   * jzagent. That runs on the robot, not the server.
#
# Built with:
#   podman build --platform linux/amd64 \
#     --build-arg CLOUDIA_VERSION=2.1.19-34 \
#     -t ghcr.io/embernet-ai/iplusmobot-cloudia:2.1.19-34 -f Containerfile .

ARG CLOUDIA_VERSION=2.1.19-34
ARG JZROUTER_VERSION=2.3.2-alpha14
ARG LIBMRPC_VERSION=0.0.38-1202
ARG RCSCTL_VERSION=0.0.8

# ─── Stage 1: download + unpack the server tarball ───────────────────────────
FROM ubuntu:20.04 AS unpacker

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ARG CLOUDIA_VERSION
WORKDIR /tmp
# install_cloudia.sh copies every non-.sh entry of the tarball into bin/. The
# vendor scripts it skips are host maintenance for a bare-metal box and do not
# apply to a container. Same loop, minus the "keep existing config" branch,
# because an image has no existing config.
RUN set -eux; \
    base="https://github.com/Embernet-ai/iplusmobot-cloudia-packages/releases/download/v${CLOUDIA_VERSION}"; \
    name="jzcloudia_${CLOUDIA_VERSION}-dev-linux-amd64"; \
    curl -fSL --retry 3 --retry-delay 5 -o SHA256SUMS "${base}/SHA256SUMS"; \
    curl -fSL --retry 3 --retry-delay 5 -o "${name}.tar.gz" "${base}/${name}.tar.gz"; \
    grep " ${name}.tar.gz\$" SHA256SUMS | sha256sum -c -; \
    tar -xzf "${name}.tar.gz"; \
    mkdir -p /opt/jz/cloudia/bin; \
    for f in $(ls "${name}"); do \
      case "${f##*.}" in sh) ;; *) cp -r "${name}/${f}" /opt/jz/cloudia/bin/ ;; esac; \
    done; \
    test -x /opt/jz/cloudia/bin/cloudia; \
    test -x /opt/jz/cloudia/bin/cloudserver_v2

# ─── Stage 2: runtime image ──────────────────────────────────────────────────
FROM ubuntu:20.04

ARG CLOUDIA_VERSION
ARG JZROUTER_VERSION
ARG LIBMRPC_VERSION
ARG RCSCTL_VERSION

LABEL org.opencontainers.image.title="EmberNET IPLUSMOBOT Cloudia ${CLOUDIA_VERSION}"
LABEL org.opencontainers.image.description="IPLUSMOBOT Cloudia AMR monitor and dispatch server (cloudia, cloudserver_v2, cloudweb, apiserver, rcsctl, jzrouter, libmrpc) for EmberNET edge nodes. Databases run as pod sidecars."
LABEL org.opencontainers.image.vendor="Fireball Industries"
LABEL org.opencontainers.image.source="https://github.com/Embernet-ai/iplusmobot-cloudia-packages"
LABEL cloudia.version="${CLOUDIA_VERSION}"
LABEL jzrouter.version="${JZROUTER_VERSION}"

# libgomp1 + libunwind8: semantic_router_server and the jzrouter tools link
# them (ldd shows both missing on a bare 20.04). Installing libgomp1 here also
# means the jzrouter preinst finds it and never tries its own `apt install`.
# netcat-openbsd: the entrypoint waits on the sidecars with nc -z.
# curl: the vendor's update_map.sh calls rcsctl on 127.0.0.1 after a map upload.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl tini procps iproute2 tzdata \
      libgomp1 libunwind8 netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*

# The vendor refuses to run as root (cloudia-init.sh) and its postinst scripts
# chown to the invoking user, so give it a real one.
RUN groupadd --gid 1000 jz \
 && useradd --uid 1000 --gid 1000 --home-dir /opt/jz --shell /bin/bash jz

# dpkg -i, not dpkg-deb -x. rcsctl reads the router version with
# `dpkg -s jzrouter`, and with the files merely extracted it logs
# "got jzrouter version:" empty and "invalid semver". Installed properly it
# reports 2.3.2-alpha14. The vendor postinst scripts are safe here: rcsctl's
# exits before touching systemd when there is no systemd, and its crontab line
# fails harmlessly because there is no cron in a container.
#
# jzrouter ships ~200 MB of headers, static libs and a test binary. Nothing at
# runtime uses them, so they go in the same layer they arrive in.
RUN set -eux; \
    base="https://github.com/Embernet-ai/iplusmobot-cloudia-packages/releases/download/v${CLOUDIA_VERSION}"; \
    mkdir /tmp/debs; cd /tmp/debs; \
    curl -fSL --retry 3 --retry-delay 5 -o SHA256SUMS "${base}/SHA256SUMS"; \
    for f in "libmrpc_${LIBMRPC_VERSION}.deb" "jzrouter_${JZROUTER_VERSION}_amd64.deb" "rcsctl_${RCSCTL_VERSION}_amd64.deb"; do \
      curl -fSL --retry 3 --retry-delay 5 -o "$f" "${base}/$f"; \
      grep " ${f}\$" SHA256SUMS | sha256sum -c -; \
    done; \
    SUDO_USER=jz dpkg -i libmrpc_*.deb jzrouter_*.deb rcsctl_*.deb; \
    cd /; rm -rf /tmp/debs \
      /opt/jz/rcs/jzrouter/include /opt/jz/rcs/jzrouter/lib \
      /opt/jz/rcs/jzrouter/test /opt/jz/rcs/jzrouter/cmake; \
    test "$(dpkg -s jzrouter | sed -n 's/^Version: //p')" = "${JZROUTER_VERSION}"

COPY --from=unpacker --chown=1000:1000 /opt/jz/cloudia /opt/jz/cloudia

# /opt/jz/log is jzrouter's default log_dir and must exist. spaces/ is where
# update_map.sh copies maps for each space, logs/ is rcsctl's.
RUN install -d -o 1000 -g 1000 /opt/jz/log /opt/jz/rcs/spaces /opt/jz/rcs/logs \
 && chown 1000:1000 /opt/jz /opt/jz/rcs

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER jz
WORKDIR /opt/jz/cloudia/bin

# Ports (all verified listening in a running pod, not read off the manual):
#   9000   cloudweb          Monitor and Dispatch System web UI
#   9669   cloudia           component manager web UI
#   10000  rcsctl            Space Management web UI
#   8800   gohttpserver      file share (basic auth cloudia:cloudia)
#   8858   apiserver         REST API
#   8848   apiserver         TCP API
#   16666  cloudserver_v2    robot agent connection (jzagent server_addr)
#   17778  cloudserver_v2    robot file server / inner API
#   15001+ per space         mapf / mrpc / libmrpc UI, three per space
EXPOSE 9000/tcp 9669/tcp 10000/tcp 8800/tcp 8858/tcp 8848/tcp 16666/tcp 17778/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["server"]
