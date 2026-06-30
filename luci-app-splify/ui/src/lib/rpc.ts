// Bridge to the LuCI `splify` ubus object (registered by the rpcd plugin). The
// host view (view/splify/home.js) exposes LuCI's rpc module on window.luci_rpc
// before mounting React. Every method here is a thin wrapper over splify-ctl on
// the router, so the dashboard, the inbound REST API and the outbound agent all
// drive the exact same backend.

declare global {
  interface Window {
    luci_rpc: any
    L: any
    ui: any
  }
}

function decl(method: string, params?: string[]) {
  const rpc = window.luci_rpc
  if (!rpc) throw new Error('LuCI RPC bridge not found (window.luci_rpc)')
  return rpc.declare({ object: 'splify', method, params })
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
    fail_count: number; lan_iface: string; lan_cidr: string
  }
  endpoints: Endpoint[]
  lists: ListRow[]
  checks: Check[]
}
export interface EventRow { ts: number; kind: string; from: string; to: string; reason: string }
export interface ApiInfo {
  enabled: string; agent_enabled: string; has_token: boolean; token: string
  control_internal: string; control_external: string; has_access_key: boolean
  enrolled: string; node_id: string; interval: string; allow_subnet: string
  agent_running: boolean; last_poll: string; last_result: string
}

export const rpc = {
  status: (): Promise<Status> => decl('status')(),
  events: (): Promise<{ events: EventRow[] }> => decl('events')(),
  action: (name: string, iface = ''): Promise<{ code: number; stdout: string }> =>
    decl('action', ['name', 'iface'])(name, iface),
  // reveal=1 returns private keys → write-gated method (kept out of the read ACL).
  exportCfg: (reveal = 0): Promise<any> => reveal ? decl('config_reveal')() : decl('config_export')(),
  importCfg: (data: any): Promise<any> => decl('config_import', ['data'])(JSON.stringify(data)),
  wgGet: (iface: string, reveal = 0): Promise<any> => reveal ? decl('wg_reveal', ['iface'])(iface) : decl('wg_get', ['iface'])(iface),
  wgSet: (iface: string, data: any): Promise<any> => decl('wg_set', ['iface', 'data'])(iface, JSON.stringify(data)),
  wgImport: (iface: string, conf: string): Promise<any> => decl('wg_import', ['iface', 'conf'])(iface, conf),
  apiGet: (): Promise<ApiInfo> => decl('api_get')(),
  apiToken: (): Promise<{ token: string }> => decl('api_token')(),
  apiSet: (data: any): Promise<any> => decl('api_set', ['data'])(JSON.stringify(data)),
  tokenRegen: (): Promise<{ token: string }> => decl('token_regen')(),
  connect: (data: any): Promise<any> =>
    decl('connect', ['data'])(typeof data === 'string' ? data : JSON.stringify(data)),
  enroll: (): Promise<any> => decl('enroll')(),
}
