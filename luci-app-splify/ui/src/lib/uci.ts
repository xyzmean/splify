// Bridge to LuCI's `uci` + `network` frontend modules. The host view
// (view/splify/settings.js) exposes them on window before mounting React, the
// same way home.js exposes window.luci_rpc for the dashboard. Every read here
// comes from the uci.load('splify') snapshot; every write stages a change in
// the session change-set — LuCI's own top bar "N unsaved changes" indicator
// picks those up automatically, same as the stock form-based pages did.

declare global {
  interface Window {
    luci_uci: any
    luci_network: any
  }
}

const CONFIG = 'splify'

function u() {
  const uci = window.luci_uci
  if (!uci) throw new Error('LuCI uci bridge not found (window.luci_uci)')
  return uci
}

// uci.js returns a bare string for a single-value list option and an array
// only once there are 2+ values — normalise to an array everywhere we treat
// something as a DynamicList.
export function arr(v: unknown): string[] {
  if (v == null || v === '') return []
  return Array.isArray(v) ? v.map(String) : [String(v)]
}

export interface Section {
  '.name': string
  '.type': string
  [k: string]: any
}

export const uci = {
  load: (): Promise<void> => u().load(CONFIG),
  get: (sid: string, opt: string): any => u().get(CONFIG, sid, opt),
  set: (sid: string, opt: string, val: string | string[] | undefined) => {
    if (val === undefined || val === '') u().unset(CONFIG, sid, opt)
    else u().set(CONFIG, sid, opt, val)
  },
  sections: (type: string): Section[] => (u().sections(CONFIG, type) || []) as Section[],
  add: (type: string): string => u().add(CONFIG, type),
  remove: (sid: string) => u().remove(CONFIG, sid),
  save: (): Promise<any> => u().save(),
  apply: (): Promise<any> => u().apply(),
  // Discard the in-memory change-set (used after a failed save so the form
  // doesn't drift from what's actually on disk).
  unload: () => { try { u().unload(CONFIG) } catch { /* */ } },
}

// Interfaces using the amneziawg/wireguard proto — same lookup the old
// settings.js form used to populate the endpoint grid's "Интерфейс" column.
export async function wgIfaces(): Promise<string[]> {
  const net = window.luci_network
  if (!net) return []
  const networks = await net.getNetworks()
  return (networks || [])
    .filter((n: any) => { const p = n.getProtocol(); return p === 'amneziawg' || p === 'wireguard' })
    .map((n: any) => n.getName())
}

// IP → "name (ip)" suggestions for the device-rules IP field, ported 1:1 from
// the old settings.js ipHints() helper.
export function ipHints(hints: any): [string, string][] {
  const out: [string, string][] = []
  if (!hints || typeof hints !== 'object') return out
  const obj = (hints.hosts && typeof hints.hosts === 'object') ? hints.hosts : hints
  Object.keys(obj).forEach((mac) => {
    const h = obj[mac] || {}
    let ips: string[] = []
    if (typeof h.ipv4 === 'string') ips.push(h.ipv4)
    if (Array.isArray(h.ipaddrs)) ips = ips.concat(h.ipaddrs)
    if (Array.isArray(h.ipv4addrs)) ips = ips.concat(h.ipv4addrs)
    ips.forEach((ip) => {
      if (typeof ip === 'string' && /^\d+\.\d+\.\d+\.\d+/.test(ip)) {
        const bare = ip.split('/')[0]
        out.push([bare, h.name ? `${h.name} (${bare})` : bare])
      }
    })
  })
  return out
}
