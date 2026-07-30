// Bridge to the LuCI `splify` ubus object (registered by the rpcd plugin). The
// host view (view/splify/home.js) exposes LuCI's rpc module on window.luci_rpc
// before mounting React. Every method here is a thin wrapper over splify-ctl on
// the router, so the dashboard, the inbound REST API and the outbound agent all
// drive the exact same backend.
//
// Wrapped in a SplifyClient class: the declarators are memoised per method
// (rpc.declare is cheap but was called on every single invocation before, and a
// couple of call sites — notably lib/uci.ts — still reach for `declare()`
// directly, so it stays public), and the splify-specific error surface
// ("bridge not found") is centralised here instead of re-checked at each use.

declare global {
  interface Window {
    luci_rpc: any
    L: any
    ui: any
  }
}

export type Sev = 'OK' | 'WARN' | 'FIXABLE' | 'FAIL'

export interface Endpoint {
  iface: string; type: string; priority: string; present: boolean
  handshake_age: number; rx: number; tx: number; health: string
  zone: string; masq: boolean; forwarding: boolean
}
export interface ListRow {
  name: string; enabled: boolean; count: number; min: number
  age: number; ok: boolean; file_count?: number
}
export interface Check { severity: Sev; category: string; message: string; fix: string }
export interface Status {
  overall: Sev
  summary: {
    mode: string; state: string; active_iface: string; killswitch: number
    fail_count: number; lan_iface: string; lan_cidr: string; zapret_version: string
    update_available?: boolean; update_version?: string
  }
  endpoints: Endpoint[]
  lists: ListRow[]
  checks: Check[]
}
export interface EventRow { ts: number; kind: string; from: string; to: string; reason: string }
export interface SingboxIface {
  iface: string; protocol: 'vless' | 'hysteria2'; server: string; port: string
  security: string; network: string; name: string
}
export interface ApiInfo {
  enabled: string; agent_enabled: string; has_token: boolean; token: string
  control_internal: string; control_external: string; has_access_key: boolean
  enrolled: string; node_id: string; interval: string; allow_subnet: string
  agent_running: boolean; last_poll: string; last_result: string
}
// status + events in a single ubus round-trip (one doctor fork). Used by the
// dashboard's initial load + refresh; falls back to status()+events() in
// App.tsx if the running backend predates the `snapshot` method.
export interface Snapshot {
  status: Status
  events: EventRow[]
}

export class SplifyClient {
  /** The underlying LuCI rpc module (also exposed for lib/uci.ts' direct
   *  uci.commit call, which has no splify equivalent). */
  private readonly luciRpc: any
  /** Memoised declarators keyed by "<method>|<params>" — rpc.declare itself is
   *  idempotent but not free, and the previous object re-ran it per call. */
  private readonly decls = new Map<string, (...args: any[]) => Promise<any>>()

  constructor() {
    const luciRpc = typeof window !== 'undefined' ? window.luci_rpc : undefined
    if (!luciRpc) {
      throw new Error('LuCI RPC bridge not found (window.luci_rpc)')
    }
    this.luciRpc = luciRpc
  }

  /** Public so lib/uci.ts can declare its own (uci.commit) call. */
  declare(method: string, params?: string[]) {
    const key = method + '|' + (params ? params.join(',') : '')
    const cached = this.decls.get(key)
    if (cached) return cached
    const fn: (...args: any[]) => Promise<any> = this.luciRpc.declare({ object: 'splify', method, params })
    this.decls.set(key, fn)
    return fn
  }

  // ── read path ────────────────────────────────────────────────────────────
  status(): Promise<Status> { return this.declare('status')() }
  events(): Promise<{ events: EventRow[] }> { return this.declare('events')() }
  /** One doctor process instead of two. Prefer this on the dashboard. */
  snapshot(): Promise<Snapshot> { return this.declare('snapshot')() }

  // ── config / wg / singbox ────────────────────────────────────────────────
  // reveal=1 returns private keys → write-gated method (kept out of the read ACL).
  exportCfg = (reveal = 0): Promise<any> =>
    reveal ? this.declare('config_reveal')() : this.declare('config_export')()
  importCfg = (data: any): Promise<any> =>
    this.declare('config_import', ['data'])(JSON.stringify(data))
  wgGet = (iface: string, reveal = 0): Promise<any> =>
    reveal ? this.declare('wg_reveal', ['iface'])(iface) : this.declare('wg_get', ['iface'])(iface)
  wgSet = (iface: string, data: any): Promise<any> =>
    this.declare('wg_set', ['iface', 'data'])(iface, JSON.stringify(data))
  wgImport = (iface: string, conf: string): Promise<any> =>
    this.declare('wg_import', ['iface', 'conf'])(iface, conf)
  singboxGet = (iface: string): Promise<any> =>
    this.declare('singbox_get', ['iface'])(iface)
  singboxImport = (iface: string, uri: string): Promise<any> =>
    this.declare('singbox_import', ['iface', 'conf'])(iface, uri)

  // ── api / agent ──────────────────────────────────────────────────────────
  apiGet = (): Promise<ApiInfo> => this.declare('api_get')()
  apiToken = (): Promise<{ token: string }> => this.declare('api_token')()
  apiSet = (data: any): Promise<any> => this.declare('api_set', ['data'])(JSON.stringify(data))
  tokenRegen = (): Promise<{ token: string }> => this.declare('token_regen')()
  connect = (data: any): Promise<any> =>
    this.declare('connect', ['data'])(typeof data === 'string' ? data : JSON.stringify(data))
  enroll = (): Promise<any> => this.declare('enroll')()

  // ── actions ──────────────────────────────────────────────────────────────
  action = (name: string, iface = ''): Promise<{ code: number; stdout: string }> =>
    this.declare('action', ['name', 'iface'])(name, iface)
}

export const rpc = new SplifyClient()
