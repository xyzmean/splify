# wg-split Roadmap

## Direction

Build wg-split into a self-diagnosing OpenWrt router product: reliable routing
core first, a clear LuCI operator panel second, and simple installation and
recovery flows third.

The next development track focuses on:

- core reliability and diagnostics;
- a LuCI dashboard that explains current state and failures;
- user-facing setup, verification, and troubleshooting.

## Shipped

- **1.7.x** — `wg-split-doctor` structured checks (`OK`/`WARN`/`FIXABLE`/`FAIL`),
  passive diagnostics, exact routing assertions; LuCI status panel + i18n.
- **2.0.0** — dashboard/settings tab split; live per-tunnel traffic; failover
  timeline (`--events`); one-click firewall auto-fix (`wg-split-firewall`);
  least-privilege rpcd/ubus object; site-to-site doctor check; transport-agnostic
  endpoint seam (`type` + `ep_*`); CI `shellcheck`/`bats`; config migration.

## Next (3.0.0)

- **Multi-transport outbounds** via sing-box (VLESS/Hysteria) as an alternative to
  WireGuard/AmneziaWG, selected per endpoint with `type=singbox`. The 2.0.0
  `ep_*` dispatch + `type` field are the seam; 3.0.0 adds the sing-box manager and
  `ep_liveness`/`ep_bringup` implementations for it.
- IPv6 policy routing; WG key/peer management; per-endpoint metrics history.

## 1. Core Reliability And Diagnostics

Goal: make the router able to answer "what is broken and what should I fix?"
without requiring manual SSH spelunking.

### Planned Work

- Add `wg-split-doctor` or extend `wg-split-status --json`.
- Return structured checks with severity: `OK`, `WARN`, `FAIL`, `FIXABLE`.
- Keep a human-readable CLI output for SSH users.
- Provide machine-readable output for LuCI.
- Reuse existing helper logic from `common.sh` where possible.

### Checks To Cover

- Endpoint interface exists.
- Endpoint interface is up or can be brought up.
- WireGuard/AmneziaWG handshake is recent enough.
- Health ping through each tunnel works.
- `route_allowed_ips=0` is applied for endpoint peers.
- Firewall zone exists for each endpoint.
- Endpoint firewall zone has `masq=1`.
- LAN to endpoint-zone forwarding exists.
- `ip rule` entries match expected wg-split priorities.
- Route table `200` contains the expected default route or blackhole.
- Killswitch state matches config and runtime state.
- nft sets exist: `ipsum`, `ru`, `nozapret` where applicable.
- nft set counts are above configured minimums.
- Downloaded list files exist and are not stale.
- dnsmasq nftset drop-in is present in the live dnsmasq conf-dir.
- zapret is available and running when enabled.
- Runtime state file matches observed routes and active tunnel.

### First Sprint

1. Add `wg-split-doctor`.
2. Implement text output.
3. Implement `--json` output.
4. Move shared status/diagnostic helpers into `common.sh` only when reuse is real.
5. Keep `wg-split-status` as a compact runtime snapshot, or make it call doctor
   for the diagnostic section.

## 2. LuCI Operator Panel

Goal: replace raw status text with a useful control panel that shows current
state, warnings, and direct actions.

### Planned Work

- Consume `wg-split-doctor --json`.
- Show top-level state:
  - active path: `vpn:<iface>`, `zapret`, `wan`, or `killswitch`;
  - routing mode;
  - killswitch status;
  - active endpoint;
  - fail counter.
- Show endpoint rows:
  - priority;
  - interface name;
  - handshake age;
  - health result;
  - firewall zone;
  - masquerading status;
  - LAN forwarding status.
- Show list state:
  - ipsum count;
  - ru/cn count;
  - nozapret count;
  - last update timestamp where available;
  - stale or missing list warnings.
- Show dnsmasq/domain tagging state.
- Show zapret availability and runtime state.
- Add action buttons:
  - Apply;
  - Restart service;
  - Run diagnostics;
  - Refresh ipsum;
  - Refresh ru/cn;
  - Refresh domains;
  - Emergency disable.

### UX Rule

LuCI should not just show logs. It should explain the next useful action, for
example:

- "Endpoint `wg0` is not in a firewall zone."
- "Zone `vpn` has masquerading disabled."
- "No forwarding from `lan` to `vpn`."
- "ipsum set is empty after firewall reload; refresh or re-apply."

## 3. Setup, Verification, And Recovery

Goal: make installation and first successful run straightforward for users who
are not debugging OpenWrt internals every day.

### Planned Work

- Rewrite README around three common scenarios:
  - `blocklist`;
  - `full`;
  - `split`.
- Add a post-install verification flow:
  - install packages;
  - configure endpoint;
  - run `wg-split-doctor`;
  - confirm active route;
  - confirm list counts;
  - confirm LuCI status.
- Add troubleshooting for common failures:
  - no endpoint configured;
  - no WireGuard/AmneziaWG interface detected;
  - missing firewall zone;
  - missing `masq`;
  - missing `lan -> tunnel-zone` forwarding;
  - empty nft sets after reload;
  - bad list URL;
  - zapret installed but not running;
  - killswitch blackholed traffic.
- Consider a `wg-split-setup` helper later if diagnostics show repeated
  fixable first-run issues.
- Add first-run hints in LuCI when no endpoints or no WG/AWG interfaces exist.

## Suggested Order

1. `wg-split-doctor` text output.
2. `wg-split-doctor --json`.
3. LuCI diagnostic panel fed by JSON.
4. LuCI action buttons for refresh/restart/apply/disable.
5. README verification and troubleshooting rewrite.
6. Optional first-run setup helper.

## Non-Goals For This Track

- IPv6 routing.
- New policy engines or per-domain priority systems.
- Managing WireGuard keys or peer configuration.
- Replacing zapret configuration management.
- Large refactors of existing routing logic without a diagnostic need.
