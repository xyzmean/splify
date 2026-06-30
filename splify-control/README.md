# splify-control (reference dashboard)

A tiny, dependency-free **reference** control plane for splify routers. The real
dashboard is an external tool — this exists so you have a working server on day
one and a runnable spec of [the protocol](PROTOCOL.md).

It is a single Python 3.7+ file (`splify-control`), stdlib only. Storage is one
JSON file per node under `--data-dir`.

## What it does

- **Public node API** (routers poll this over WAN, even with their tunnel down):
  - `POST /enroll` — register a node's self-generated token, gated by the one-time
    `access_key`.
  - `POST /poll` — receive a node's status report, return the desired snapshot
    when there's a pending change (else `{"noop":true}`).
- **WG-only admin console** — a single-page UI to see every node's live status and
  push config (AmneziaWG obfuscation knobs, endpoint, `.conf` import, or a full
  desired snapshot). Bind it to the WG address so it's reachable only from inside
  the VPN.

## Run it (e.g. on the WG server, 10.8.0.1)

```sh
./splify-control \
  --node-host 0.0.0.0      --node-port 8443 \   # public: routers poll here
  --admin-host 10.8.0.1    --admin-port 8088 \   # WG-only: management console
  --external-url https://vpn.example.net:8443 \  # what routers use over WAN
  --internal-url http://10.8.0.1:8443 \          # what routers use over the tunnel
  --data-dir /var/lib/splify-control
```

On first start it generates and prints the **connection JSON** (also at
`GET /admin/api/connect`, or `./splify-control --print-connect`). Copy it into
each router: LuCI → Дополнительно → API → «Подключить», or:

```sh
ssh root@router 'splify-ctl connect' <<'JSON'
{"internal":"http://10.8.0.1:8443","external":"https://vpn.example.net:8443","access_key":"...."}
JSON
```

The router then enrolls (registering its own token) and starts polling. It shows
up in the console within one interval.

## TLS (do this for production)

Snapshots can carry private keys when you rotate them, and the node listener is
public. Either pass a cert directly:

```sh
./splify-control --tls-cert /etc/ssl/vpn.crt --tls-key /etc/ssl/vpn.key ...
```

…or, recommended, terminate TLS at nginx/caddy in front and point `--external-url`
at the public HTTPS address. The admin console stays WG-only either way.

## Options

| flag | meaning | default |
|------|---------|---------|
| `--node-host` / `--node-port` | public node-API bind | `0.0.0.0:8080` |
| `--admin-host` / `--admin-port` | admin console bind — **set to the WG IP** | `127.0.0.1:8088` |
| `--data-dir` | per-node JSON storage | `/var/lib/splify-control` |
| `--access-key` | enrollment key (auto-generated + persisted if omitted) | — |
| `--internal-url` / `--external-url` | URLs put into the connection JSON | — |
| `--admin-token` | optional bearer for the admin API (defense in depth) | — |
| `--tls-cert` / `--tls-key` | enable HTTPS | — |
| `--print-connect` | print the connection JSON and exit | — |

## systemd unit (example)

```ini
[Unit]
Description=splify control plane
After=network-online.target

[Service]
ExecStart=/opt/splify-control/splify-control \
  --node-host 0.0.0.0 --node-port 8443 \
  --admin-host 10.8.0.1 --admin-port 8088 \
  --external-url https://vpn.example.net:8443 \
  --internal-url http://10.8.0.1:8443 \
  --data-dir /var/lib/splify-control
Restart=always
DynamicUser=yes
StateDirectory=splify-control

[Install]
WantedBy=multi-user.target
```

> Firewall: allow the **node port** from the internet (or restrict to your
> routers' WAN ranges if known), and keep the **admin port** on the WG interface
> only. See [PROTOCOL.md](PROTOCOL.md) for the full wire contract.
