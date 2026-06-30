// Presentation helpers shared across the dashboard (ported from the 2.0
// dashboard.js so the React UI reads identically).
import type { Sev, Endpoint } from './rpc'

export const SEV_TEXT: Record<Sev, string> = {
  OK: 'text-emerald-600 dark:text-emerald-400',
  WARN: 'text-amber-600 dark:text-amber-400',
  FIXABLE: 'text-orange-600 dark:text-orange-400',
  FAIL: 'text-rose-600 dark:text-rose-400',
}
export const SEV_BG: Record<Sev, string> = {
  OK: 'bg-emerald-500',
  WARN: 'bg-amber-500',
  FIXABLE: 'bg-orange-500',
  FAIL: 'bg-rose-500',
}
export const SEV_BORDER: Record<Sev, string> = {
  OK: 'border-emerald-500',
  WARN: 'border-amber-500',
  FIXABLE: 'border-orange-500',
  FAIL: 'border-rose-500',
}

export function fmtAge(s: number | null | undefined): string {
  if (s == null || s < 0 || s >= 999999) return '—'
  if (s < 120) return s + ' с'
  if (s < 7200) return Math.round(s / 60) + ' мин'
  return Math.round(s / 3600) + ' ч'
}

export function fmtRate(bps: number): string {
  if (bps == null || !isFinite(bps) || bps < 1) return '0'
  const u = ['Б/с', 'КБ/с', 'МБ/с', 'ГБ/с']
  let i = 0
  while (bps >= 1000 && i < u.length - 1) { bps /= 1000; i++ }
  return (bps < 10 && i > 0 ? bps.toFixed(1) : Math.round(bps).toString()) + ' ' + u[i]
}

export function fmtBytes(b: number): string {
  if (!b) return '0'
  const u = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ']
  let i = 0
  while (b >= 1024 && i < u.length - 1) { b /= 1024; i++ }
  return (b < 10 && i > 0 ? b.toFixed(1) : Math.round(b).toString()) + ' ' + u[i]
}

export function fmtWhen(ts: number): string {
  const d = Date.now() / 1000 - ts
  if (d < 0) return 'только что'
  if (d < 60) return Math.round(d) + ' с назад'
  if (d < 3600) return Math.round(d / 60) + ' мин назад'
  if (d < 86400) return Math.round(d / 3600) + ' ч назад'
  return new Date(ts * 1000).toLocaleString()
}

export function fmtUnix(s: string): string {
  const n = Number(s)
  if (!n) return 'никогда'
  return fmtWhen(n)
}

// Δbytes / Δt between polls → per-iface rate. Mutates the passed sample store.
export type RateSample = Record<string, { rx: number; tx: number; t: number }>
export function ratesFor(e: Endpoint, now: number, store: RateSample) {
  const p = store[e.iface]
  let rxr = 0, txr = 0
  if (p && now > p.t && e.rx >= p.rx && e.tx >= p.tx) {
    const dt = (now - p.t) / 1000
    rxr = (e.rx - p.rx) / dt
    txr = (e.tx - p.tx) / dt
  }
  store[e.iface] = { rx: e.rx || 0, tx: e.tx || 0, t: now }
  return { rx: rxr, tx: txr }
}

// Human label + icon for the live path state (vpn:<if> | zapret | killswitch | wan).
export function pathLabel(state: string): { title: string; icon: string } {
  if (/^vpn:/.test(state)) return { title: `Защищено — трафик идёт через VPN (${state.replace(/^vpn:/, '')})`, icon: '🛡' }
  if (state === 'zapret') return { title: 'Нет туннеля — работает обход DPI (zapret)', icon: '⚠' }
  if (state === 'killswitch') return { title: 'Туннели недоступны — трафик заблокирован (kill switch)', icon: '⛔' }
  if (state === 'wan') return { title: 'Прямое подключение — VPN не активен', icon: '🌐' }
  return { title: 'Состояние неизвестно', icon: '?' }
}

export const EVENT_META: Record<string, { i: string; cls: string; ru: string }> = {
  switch: { i: '⇄', cls: 'text-amber-500', ru: 'переключение' },
  recover: { i: '✓', cls: 'text-emerald-500', ru: 'восстановление' },
  restart: { i: '↻', cls: 'text-amber-500', ru: 'перезапуск' },
  killswitch: { i: '⛔', cls: 'text-rose-500', ru: 'блокировка' },
  zapret_fallback: { i: '⚠', cls: 'text-orange-500', ru: 'откат на zapret' },
  wan_fallback: { i: '✕', cls: 'text-rose-500', ru: 'откат на WAN' },
}
