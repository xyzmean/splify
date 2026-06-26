# Changelog

All notable changes to wg-split are documented here. Versions follow the package
`VERSION` file; the UCI config schema only ever changes **additively** (no renames
or removals), so upgrades never break an existing `/etc/config/wg-split`.

## 2.0.0

A major release for new UI/UX, firewall, observability and packaging surfaces —
**not** a config break. 1.7.x configs keep working as-is; a uci-defaults migration
fills in the new defaults idempotently.

### Added
- **LuCI dashboard split into two tabs** — `Status` (diagnostics) and `Settings`
  (the UCI form), under `admin/services/wg-split`.
- **Live per-tunnel traffic** — `wg-split-doctor` reports cumulative `rx`/`tx`
  bytes per endpoint; the dashboard derives live speed and shows it on the routing
  chain and the tunnels table.
- **Failover timeline** — transitions (`switch`, `recover`, `restart`,
  `killswitch`, `zapret_fallback`, `wan_fallback`) are journalled to a RAM ring
  buffer (`/var/run/wg-split-events`) and rendered as a timeline.
  `wg-split-doctor --events` emits them as JSON.
- **Firewall auto-fix** — new `wg-split-firewall {check|fix} <iface>` creates or
  repairs the endpoint’s firewall zone (accept-all + masquerading + mtu_fix, with
  lan↔zone and zone→wan forwarding), modelled on a known-good AmneziaWG zone. The
  dashboard adds a **“Fix automatically”** button on every firewall finding.
- **rpcd/ubus object `wg-split`** (`status`/`events`/`action`) — the LuCI app now
  talks to it over ubus instead of broad `file:exec`.
- **Site-to-site diagnostics** — the doctor flags any `vpn_cidr` (a peer LAN) that
  is not actually routed into the active tunnel; “VPN subnets” is labelled for
  site-to-site use.
- **Transport-agnostic endpoint seam** — endpoints carry a `type` (default `wg`);
  `ep_present`/`ep_liveness`/`ep_egress_dev`/`ep_transfer`/`ep_bringup`/`ep_restart`
  dispatch on it, paving the way for a sing-box (VLESS/Hysteria) backend in 3.0
  without core changes.
- **Per-device IP picker** — the device-override IP field offers a datalist of
  known LAN hosts (DHCP/neighbour hints).
- **CI lint + tests** — `shellcheck` over the shell core and `bats` unit tests for
  the pure logic (`clean_ip_list`, `fw_bool`, `json_esc`, `_rank`, endpoint
  parsing), plus the existing off-box doctor self-test.
- **Config migration** — `/etc/uci-defaults/99-wg-split-migrate` stamps `type=wg`
  on existing endpoints (additive, idempotent).

### Changed
- **Least-privilege ACL** — `luci-app-wg-split` now grants only the three
  `wg-split` ubus methods (read = `status`/`events`, write = `action`); the broad
  `file:exec` grants are removed.
- The dashboard and doctor use **generic “endpoint / last seen / liveness”** wording
  instead of hardcoding “WireGuard/handshake”, ahead of multi-transport support.
- Failover now brings endpoints up / restarts them through the `ep_*` dispatch
  helpers (identical behaviour for `wg`).

### Notes
- In **blocklist/split** modes the `ru/cn` list is intentionally **not** wired as an
  nft routing set (it only feeds the zapret bypass via its downloaded file), so the
  dashboard showing the `ru` set at `0` live entries is expected and not a fault —
  the doctor only flags a low count in `full` mode, where the set is actually used.
