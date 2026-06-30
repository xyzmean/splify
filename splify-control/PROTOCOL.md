# splify control-plane protocol (v1)

This is the wire contract between a **splify router** (the agent, `splify-agent`)
and a **dashboard** (control plane). The dashboard is an *external* tool and may
live in its own repository — anything that implements the endpoints below works.
`splify-control/splify-control` in this repo is a small **reference**
implementation you can run as-is or read as a spec.

Design constraints that shape this protocol:

- Routers sit behind **carrier-grade NAT** with no static IP → nothing can
  connect *in*. Every exchange is **router → dashboard** (outbound).
- The channel must keep working when the **WG tunnel is down** → the agent can
  reach the dashboard over the public internet (WAN), so the dashboard needs a
  publicly reachable address, and the management UI is kept on a separate,
  WG-only address.
- No host is hardcoded. A router learns the dashboard from a **connection JSON**.

## 1. Connection JSON (dashboard → operator → router)

The dashboard generates this blob; the operator pastes it into the router once
(LuCI → Дополнительно → API → «Подключить», or `splify-ctl connect < blob.json`).

```json
{
  "version": 1,
  "internal": "http://10.8.0.1:8080",
  "external": "https://vpn.example.net:8443",
  "access_key": "<one-time enrollment key>",
  "node_id": "optional-suggested-id"
}
```

- `internal` — dashboard URL reachable over the **tunnel / WG** side. Tried first
  (kept private). May be empty.
- `external` — dashboard URL reachable over the **public internet / WAN**. The
  CGNAT + tunnel-down fallback. May be empty (but then recovery-when-down won't
  work).
- `access_key` — a **one-time** enrollment secret. The router uses it *only* to
  register, then discards it.
- `node_id` — optional suggested id; the router generates one if absent.

At least one of `internal` / `external` must be present.

## 2. Enrollment — `POST {base}/enroll`

The router generates its **own** long-lived communication token (`node_token`,
CSPRNG) and registers it, authenticated by the one-time `access_key`.

Request:

```
POST {base}/enroll
Authorization: Bearer <access_key>
Content-Type: application/json

{ "node_id": "router-7a3f", "node_token": "<self-generated>", "hostname": "rt1" }
```

Response `200`:

```json
{ "ok": true, "node_id": "router-7a3f" }
```

The dashboard MUST store `node_token` for that `node_id` and reject future polls
whose bearer token doesn't match. It MAY override `node_id` in the response (the
router adopts it). Errors: `401` bad access_key, `400` bad body, `503`
enrollment disabled.

After a `200`, the router sets `enrolled=1`, **clears** the `access_key`, and
authenticates every subsequent poll with `node_token`.

## 3. Poll — `POST {base}/poll`

One round trip per tick (NAT-friendly): the router reports its state **and**
receives the desired state in the reply.

Request:

```
POST {base}/poll
Authorization: Bearer <node_token>
X-Splify-Node: <node_id>
Content-Type: application/json

{
  "node": "router-7a3f",
  "ts": 1782742149,
  "agent": "splify-agent/1",
  "applied_gen": 3,
  "status": { ...splify-doctor --json... },
  "config": { ...masked snapshot, see §5... }
}
```

- `applied_gen` — the generation the router has already converged to.
- `status` — the full `splify-doctor --json` (overall, summary, endpoints, lists,
  checks). The dashboard renders this.
- `config` — the current node snapshot with **secrets masked** (no private keys).

Response — **no pending change** (the common case):

```json
{ "noop": true, "generation": 3 }
```

Response — **a change is pending** (`applied_gen < generation`): the **desired
snapshot** (§5) plus its `generation`:

```json
{ "generation": 4, "splify": { ... }, "wg": { "awg0": { ... } },
  "sites": ["10.8.2.0/24", "10.8.3.0/24"] }
```

The router applies it, persists `generation`, and reports the new `applied_gen`
on the next poll — so the dashboard then returns `noop` and the router does **not
re-apply** (this is what prevents a tunnel-bounce loop). Errors: `401` bad token,
`403` not enrolled, `400` bad body.

### Site-to-site mesh (`sites`)

The desired snapshot may carry a `sites` array of remote LAN subnets (CIDR). The
router installs a route to each over the tunnel (main table) and excludes them
from the tunnel zone's masquerade, giving **true site-to-site** (real source
IPs) — see `splify-ctl sites-apply`. An empty `sites: []` clears them. The
dashboard computes this per node from every node's reported LAN (`config.lan`,
§5): full mesh = each node gets the set of all OTHER nodes' LANs. `sites` changes
bump `generation` like any other desired change, so it converges once and never
loops.

## 4. Generation discipline

The dashboard keeps an integer `generation` per node, **incremented every time an
operator publishes a new desired snapshot**. Return the desired snapshot only
while `applied_gen < generation`; otherwise return `noop`. This is the entire
convergence mechanism — keep it simple and monotonic.

## 5. Snapshot shape (the unit of config)

Produced by `splify-ctl export` and consumed by `splify-ctl import`. Import is a
**merge**: only the keys present are touched (so you can push just an endpoint
host without resending keys). `private_key` / `preshared_key` are **masked** on
the router's report (replaced by `has_private_key` / `has_preshared_key` booleans)
and only sent by the dashboard when actually rotating a secret.

```json
{
  "version": 1,
  "node": "router-7a3f",
  "lan": "10.8.1.0/24",
  "sites": "10.8.2.0/24",
  "splify": {
    "global": { "mode": "blocklist", "interval": "180", "killswitch": "0",
                "lan_iface": "br-lan", "lan_cidr": "192.168.1.0/24",
                "health_target": ["1.1.1.1"], "health_url": "https://...",
                "zapret_enabled": "1", "ipsum_enabled": "1", "ipsum_url": "...",
                "ru_enabled": "1", "ru_url": "...", "vpn_domains_url": "",
                "ignore_domains_url": "", "vpn_cidr": [], "direct_cidr": [],
                "vpn_domain": [], "direct_domain": [] },
    "endpoints": [ { "iface": "awg0", "priority": "1", "type": "wg" } ],
    "devices":   [ { "ip": "192.168.1.50", "mode": "vpn" } ]
  },
  "wg": {
    "awg0": {
      "proto": "amneziawg",
      "has_private_key": true,
      "private_key": "<only when rotating>",
      "addresses": ["10.8.0.2/24"],
      "dns": ["8.8.8.8"],
      "awg": { "jc":"120","jmin":"40","jmax":"70","s1":"0","s2":"0",
               "h1":"1","h2":"2","h3":"3","h4":"4","i1":"<b 0x...>" },
      "peers": [ { "public_key":"...", "has_preshared_key":true,
                   "preshared_key":"<only when rotating>",
                   "endpoint_host":"45.144.53.1", "endpoint_port":"500",
                   "allowed_ips":["0.0.0.0/0"], "persistent_keepalive":"",
                   "route_allowed_ips":"0" } ]
    }
  }
}
```

`endpoints`, `devices` and a wg interface's `peers` array are **replaced
wholesale** when present (small ordered lists); everything else merges. The
import preserves a peer's `preshared_key` across a replace when the new peer omits
it (matched by `public_key`), so a masked round-trip never wipes a PSK.

## 6. Security notes

- The poll/enroll listener is **public** (CGNAT routers reach it over WAN) — put
  **TLS** in front of it (the reference server supports `--tls-cert/--tls-key`, or
  run it behind nginx/caddy). Snapshots can carry private keys when rotating.
- The bearer token authenticates but does **not** encrypt — TLS is what protects
  the payload.
- Bind the **admin/management UI** to the **WG address only** so it is never
  exposed to the public internet (reference: `--admin-host 10.8.0.1`).
- `access_key` is one-time and cleared on the router after enrollment; rotate it
  on the dashboard between onboarding batches.
- Compare tokens in constant time (`hmac.compare_digest` / SHA-256 compare).
