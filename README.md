# EmberNET IPLUSMOBOT Cloudia Packages

IPLUSMOBOT Cloudia, the AMR monitor and dispatch server, packaged as a container for EmberNET edge nodes.

The chart that deploys it lives in [iplusmobot-cloudia-helm](https://github.com/Embernet-ai/iplusmobot-cloudia-helm).

## Releases

The vendor files live on GitHub Releases, not in git. Every release carries a `SHA256SUMS`, and the build refuses any file that doesn't match it.

`v2.1.19-34`:

- `jzcloudia_2.1.19-34-dev-linux-amd64.tar.gz`: cloudia, cloudserver_v2, cloudweb, apiserver, gohttpserver
- `jzrouter_2.3.2-alpha14_amd64.deb`: multi-robot path planner
- `libmrpc_0.0.38-1202.deb`: multi-robot path coordination
- `rcsctl_0.0.8_amd64.deb`: Space Management
- `jzagent_2.1.19-34_amd64.deb`: goes on the **robot**, not in this image
- `cloudia-init.sh`: the vendor's bare-metal installer, kept for reference

## Image

`ghcr.io/embernet-ai/iplusmobot-cloudia:2.1.19-34` (also `:latest` and `:main`). amd64 only, because that is all the vendor ships.

One image runs two roles:

- `server` waits for the databases, runs `cloudserver_v2 -dbup`, then `cloudia serve`
- `rcs` runs `rcsctl -p 10000`

MySQL 5.7, Redis and InfluxDB 1.8 are **not** in the image. Every vendor config points at 127.0.0.1, so they run as sidecars in the same pod. They have to bind to loopback only, because the chart runs on hostNetwork and a wildcard bind would put MySQL root/123456 and a passwordless Redis on the plant LAN. InfluxDB also has to leave 8088, which is Ignition Edge's port.

## Ports

These were measured on a running pod, not copied from the manual.

- 9000: cloudweb, the dispatch UI (login root / 123456)
- 10000: rcsctl, Space Management
- 9669: cloudia component manager
- 8800: file share (cloudia / cloudia)
- 8858 and 8848: apiserver REST and TCP
- 16666 and 17778: what robots connect to. Set jzagent `server_addr` to `<node IP>:16666` and `<node IP>:17778`
- 15001 and up: three ports for each space (mapf, mrpc, libmrpc UI), assigned by rcsctl

## Building

```bash
podman build --platform linux/amd64 --build-arg CLOUDIA_VERSION=2.1.19-34 \
  -t ghcr.io/embernet-ai/iplusmobot-cloudia:2.1.19-34 -f Containerfile .
```

CI builds on every push to `main` and smoke tests the real pod before it pushes anything. The smoke test fails if the migration doesn't finish, if any port stays down, if a database listens on a non-loopback address, or if rcsctl can't read the router version.
