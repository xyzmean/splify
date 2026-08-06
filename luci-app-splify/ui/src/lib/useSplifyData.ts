// The dashboard's whole data layer, in one hook.
//
// It exists because the read path is deliberately split in two on the router
// (see splify-live / splify-snapshot):
//
//   live      ~0.2s, safe to poll   -> path state, per-tunnel handshake, rx/tx
//   snapshot  cached, instant       -> diagnostics, lists, firewall, events
//
// What that buys the UI, and what this hook is responsible for:
//
//   1. FIRST PAINT IS IMMEDIATE. Both calls fire in parallel on mount and the
//      page renders whichever lands first; the old dashboard rendered nothing
//      until one blocking doctor run (4-24s on real hardware) came back.
//   2. TRAFFIC SPEED ACTUALLY WORKS. Rates are a delta between two samples of
//      the cumulative counters, so a page that never polls can only ever show
//      0 — which is exactly what the old dashboard showed. We poll `live` and
//      derive the rate from consecutive samples, using the ROUTER's own
//      timestamp for dt so a skewed browser clock can't invent traffic.
//   3. POLLING STAYS POLITE. Only while the tab is visible (a backgrounded LuCI
//      tab must not keep a router busy for hours), never overlapping, and it
//      backs off on errors instead of hammering a box that is already unhappy.
//   4. DIAGNOSTICS REFRESH WITHOUT BEING POLLED. `live` reports the cached
//      snapshot's age, so when a sweep finishes (age drops) we re-fetch the
//      snapshot once. "Обновить" just queues a sweep and lets that path pick it
//      up — no request is ever left hanging on a 20s doctor run.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { rpc, type Live, type Status, type EventRow, type Sev } from '@/lib/rpc'

const POLL_MS = 4000          // live cadence while visible, on a healthy box
const POLL_MS_MAX = 30000     // error backoff ceiling
// Adaptive cadence. `live` is ~0.2s on a filogic router but ~0.6s on a
// single-core MT7628 (measured), where polling every 4s would spend a sixth of
// the CPU answering a dashboard. So the interval follows what the router
// actually delivers: keep the gap at least ~8x the observed round-trip, which
// leaves a fast box at 4s and settles a slow one around 5-10s.
const POLL_DUTY_FACTOR = 8
const POLL_MS_SLOW_CAP = 15000
const REFRESH_TIMEOUT_MS = 90000  // give up waiting on a queued sweep

export interface Rate { rx: number; tx: number }

export interface SplifyData {
  live: Live | null
  status: Status | null
  events: EventRow[]
  /** bytes/s per iface, derived from consecutive live samples */
  rates: Record<string, Rate>
  /** worst severity known: from diagnostics, live-carried until they load */
  overall: Sev
  /** why the diagnostics half is missing, if it is (network drop, ACL, …) */
  diagError: string | null
  /** age in seconds of the diagnostics currently displayed (-1 = none yet) */
  diagAge: number
  /** a diagnostic sweep is running (queued by us or by splify-apply) */
  diagPending: boolean
  loading: boolean
  error: string | null
  /** queue a fresh sweep + pull live immediately */
  refresh: () => void
  refreshing: boolean
  /** after an action: re-read live at once and pull fresh diagnostics */
  afterAction: () => void
}

export function useSplifyData(active = true): SplifyData {
  const [live, setLive] = useState<Live | null>(null)
  const [status, setStatus] = useState<Status | null>(null)
  const [events, setEvents] = useState<EventRow[]>([])
  const [rates, setRates] = useState<Record<string, Rate>>({})
  const [error, setError] = useState<string | null>(null)
  const [diagError, setDiagError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)

  // Previous live sample per iface, for the rate delta.
  const prev = useRef<Record<string, { rx: number; tx: number; ts: number }>>({})
  // When the diagnostics we are SHOWING were computed, as a router-side unix
  // timestamp (live.ts - diagnostics.age). Absolute and monotonic, unlike the
  // age itself: comparing ages breaks the moment a sweep lands mid-poll.
  const shownDiagTs = useRef(0)
  // Router timestamp at which the user asked for fresh diagnostics; the spinner
  // stops once a snapshot computed AFTER that moment is on screen.
  const refreshWantTs = useRef(0)
  const refreshingRef = useRef(false)
  const refreshDeadline = useRef(0)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const backoff = useRef(POLL_MS)
  // Guards every async setState: the component may unmount (LuCI navigations
  // tear the view down) while a request is in flight.
  const alive = useRef(true)
  // Monotonic id so a slow snapshot can't overwrite a newer one.
  const snapReq = useRef(0)

  const pullSnapshot = useCallback(async (computedAt = 0, attempt = 0) => {
    const id = ++snapReq.current
    try {
      const snap = await rpc.snapshot()
      if (!alive.current || id !== snapReq.current) return
      // An explicitly empty snapshot means "the sweep is queued, nothing cached
      // yet" (see splify-snapshot's cold-start path). That is a loading state, not
      // a failure: the poll loop re-fetches as soon as diagnostics.age turns
      // non-negative.
      if (!snap || !snap.status) {
        setDiagError(null)
        setLoading(false)
        return
      }
      setStatus(snap.status)
      setEvents(snap.events || [])
      setDiagError(null)
      setLoading(false)
      if (computedAt) shownDiagTs.current = computedAt
      if (refreshingRef.current && computedAt >= refreshWantTs.current) {
        refreshingRef.current = false
        setRefreshing(false)
      }
    } catch (e: any) {
      if (!alive.current) return
      setLoading(false)
      // Diagnostics are supplementary: a failure here must not blank a page
      // whose live half works. But it must not leave loading skeletons up
      // forever either — that reads as "still working" when nothing is. Record
      // it separately (the shared `error` belongs to the live poll, which clears
      // it on its next success and would erase this) and retry a couple of
      // times: the usual cause is a brief drop while the tunnel re-establishes,
      // and this call is cheap.
      setDiagError(e?.message || String(e))
      if (attempt < 3) {
        setTimeout(() => { if (alive.current) void pullSnapshot(computedAt, attempt + 1) }, 4000 * (attempt + 1))
      }
    }
  }, [])

  // A router whose splify package predates splify-live (LuCI app upgraded, core
  // not yet — or an ACL that doesn't list the method) has no cheap path at all.
  // Rather than show an error, fall back to synthesising the same shape from the
  // cached snapshot and polling it slowly. Everything downstream is unaffected;
  // only the rate resolution suffers.
  const liveUnsupported = useRef(false)
  const legacyLive = useCallback(async (): Promise<Live> => {
    const snap = await rpc.snapshot()
    if (alive.current) {
      setStatus(snap.status)
      setEvents(snap.events || [])
    }
    const s = snap.status?.summary || ({} as Status['summary'])
    return {
      ts: Math.floor(Date.now() / 1000),
      summary: {
        mode: s.mode, state: s.state, active_iface: s.active_iface,
        killswitch: s.killswitch, fail_count: s.fail_count,
        lan_iface: s.lan_iface, lan_cidr: s.lan_cidr,
        zapret_version: s.zapret_version, zapret_running: !!s.zapret_version,
        update_available: !!s.update_available, update_version: s.update_version || '',
      },
      endpoints: (snap.status?.endpoints || []).map((e) => ({
        iface: e.iface, type: e.type, priority: e.priority, present: e.present,
        handshake_age: e.handshake_age, rx: e.rx, tx: e.tx, health: e.health,
      })),
      diagnostics: { age: 0, pending: false, overall: snap.status?.overall || '' },
    }
  }, [])

  const pullLive = useCallback(async () => {
    const startedAt = Date.now()
    try {
      const l = liveUnsupported.current ? await legacyLive() : await rpc.live().catch((err: any) => {
        if (/not found|No object|declared|UBUS_STATUS_NOT_FOUND|Method not found|Access denied/i.test(String(err?.message || err))) {
          liveUnsupported.current = true
          backoff.current = POLL_MS_MAX
          return legacyLive()
        }
        throw err
      })
      if (!alive.current) return
      setLive(l)
      setError(null)
      setLoading(false)
      if (!liveUnsupported.current) {
        // Let the router set the pace (see POLL_DUTY_FACTOR).
        const rtt = Date.now() - startedAt
        backoff.current = Math.min(Math.max(POLL_MS, rtt * POLL_DUTY_FACTOR), POLL_MS_SLOW_CAP)
      }

      // ── rates from consecutive samples (router clock, not browser clock) ──
      setRates((old) => {
        const next: Record<string, Rate> = { ...old }
        for (const e of l.endpoints || []) {
          const p = prev.current[e.iface]
          // Counters reset when an interface is recreated; a negative delta is
          // a reset, not negative traffic — report 0 and re-baseline.
          if (p && l.ts > p.ts && e.rx >= p.rx && e.tx >= p.tx) {
            const dt = l.ts - p.ts
            next[e.iface] = { rx: (e.rx - p.rx) / dt, tx: (e.tx - p.tx) / dt }
          } else if (!p) {
            next[e.iface] = { rx: 0, tx: 0 }
          }
          prev.current[e.iface] = { rx: e.rx, tx: e.tx, ts: l.ts }
        }
        return next
      })

      // ── fresh diagnostics landed? pull them once ──────────────────────────
      // Skipped on the legacy path: there the snapshot IS the live source, so
      // legacyLive() has already stored the diagnostics it just read.
      if (liveUnsupported.current) {
        shownDiagTs.current = l.ts
        if (refreshingRef.current) { refreshingRef.current = false; setRefreshing(false) }
      } else {
        const age = l.diagnostics?.age ?? -1
        if (age >= 0) {
          const computedAt = l.ts - age
          if (computedAt > shownDiagTs.current) void pullSnapshot(computedAt)
        }
      }
      // Safety net: a sweep that dies (OOM, reboot mid-run) must not leave the
      // Refresh button spinning forever.
      if (refreshingRef.current && Date.now() > refreshDeadline.current) {
        refreshingRef.current = false
        setRefreshing(false)
      }
    } catch (e: any) {
      if (!alive.current) return
      setError(e?.message || String(e))
      setLoading(false)
      backoff.current = Math.min(backoff.current * 2, POLL_MS_MAX)
    }
  }, [pullSnapshot, legacyLive])

  // Single self-rescheduling timer: no overlapping requests, and it simply
  // stops while the tab is hidden (resuming with an immediate read).
  // ⚡ Bolt: Also pauses polling when active=false (e.g. background tab) to
  // eliminate unnecessary React re-renders and router API calls.
  useEffect(() => {
    if (!active) return

    alive.current = true
    let stopped = false

    const tick = async () => {
      if (stopped) return
      if (document.visibilityState === 'visible') await pullLive()
      if (stopped) return
      timer.current = setTimeout(tick, backoff.current)
    }

    const onVisible = () => {
      if (document.visibilityState !== 'visible') return
      if (timer.current) clearTimeout(timer.current)
      void tick()
    }

    void pullLive()
    void pullSnapshot()
    timer.current = setTimeout(tick, POLL_MS)
    document.addEventListener('visibilitychange', onVisible)

    return () => {
      stopped = true
      alive.current = false
      if (timer.current) clearTimeout(timer.current)
      document.removeEventListener('visibilitychange', onVisible)
    }
    // Mount-only: pullLive/pullSnapshot are stable enough for this purpose and
    // re-subscribing on every render would restart the timer constantly.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active])

  // Ask for a fresh sweep. Returns immediately: the request only QUEUES the
  // work on the router (a sweep can take 20s — no browser request should sit on
  // that), and the poll loop swaps the diagnostics in when they land.
  const startRefresh = useCallback(() => {
    refreshingRef.current = true
    setRefreshing(true)
    // Router-side "now": the freshest thing we know. Falls back to the browser
    // clock only before the very first live reply.
    refreshWantTs.current = live?.ts ?? Math.floor(Date.now() / 1000)
    refreshDeadline.current = Date.now() + REFRESH_TIMEOUT_MS
    // queued:false just means a sweep is already running — same outcome.
    rpc.snapshotRefresh().catch(() => { /* keep showing the cached snapshot */ })
    void pullLive()
  }, [pullLive, live])

  // An action (apply/restart/list update) changed the box: read live at once so
  // the header reflects it, and pull diagnostics — splify-apply already queues a
  // sweep of its own, so this usually finds fresh data waiting.
  const afterAction = startRefresh

  const overall: Sev = useMemo(() => {
    if (status?.overall) return status.overall
    const carried = live?.diagnostics?.overall
    return (carried || 'OK') as Sev
  }, [status, live])

  return {
    live, status, events, rates, overall, diagError,
    diagAge: live?.diagnostics?.age ?? -1,
    diagPending: !!live?.diagnostics?.pending,
    loading, error, refresh: startRefresh, refreshing, afterAction,
  }
}
