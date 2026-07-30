import { useCallback, useEffect, useRef, useState, lazy, Suspense } from 'react'
import { rpc, type Status, type EventRow } from '@/lib/rpc'
import StatusDashboard from '@/components/StatusDashboard'

// ⚡ Bolt: Code splitting background tabs
// WgPanel and ApiPanel are heavy components only needed when their specific tabs are active.
// Using React.lazy() splits them into separate JS chunks, reducing the initial bundle size
// parsed and executed on load, which is critical for low-power router devices.
const WgPanel = lazy(() => import('@/components/WgPanel'))
const ApiPanel = lazy(() => import('@/components/ApiPanel'))

// sing-box tab is hidden — the backend (SingboxPanel.tsx + singbox_* rpc methods)
// stays in place so the feature can be re-enabled when it is finished.
// const SingboxPanel = lazy(() => import('@/components/SingboxPanel'))
import { cn } from '@/lib/utils'
import { t } from '@/lib/i18n'
import { Activity, Radio, ShieldCheck } from 'lucide-react'

type Tab = 'status' | 'wg' | 'api'

// Same left-rail navigation as the settings view — the two pages must read as
// one system, and Argon has no second-level horizontal tab row to mimic.
const NAV: { id: Tab; label: string; icon: React.ComponentType<{ className?: string }> }[] = [
  { id: 'status', label: t('Status'), icon: Activity },
  { id: 'wg', label: t('AmneziaWG'), icon: ShieldCheck },
  { id: 'api', label: t('Remote control'), icon: Radio },
]

export default function App() {
  const [tab, setTab] = useState<Tab>('status')
  const [status, setStatus] = useState<Status | null>(null)
  const [events, setEvents] = useState<EventRow[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState('')
  // Monotonic request id: if a newer refresh() starts before an older one
  // resolves, the older one's result is discarded. Prevents a late/slow reply
  // from clobbering fresher state (e.g. Apply then Restart clicked in quick
  // succession, or a stale network retry landing after a newer load).
  const reqId = useRef(0)

  // Data loads once on mount and on demand via the "Обновить" button (and after
  // any action). There is deliberately NO background polling interval: a timer
  // firing every few seconds for the lifetime of the tab was both an annoyance
  // and a steady source of work that kept the long-lived view busy.
  //
  // Prefer the combined `snapshot` call (one doctor fork = one ubus round-trip
  // for both status and events); fall back to separate status()+events() only
  // if the backend is older than the `snapshot` method (or ACL rejects it).
  const refresh = useCallback(async () => {
    const id = ++reqId.current
    try {
      const snap = await rpc.snapshot().catch(async (snapErr: any) => {
        // Old backend without `snapshot`, or the read ACL doesn't list it yet:
        // degrade to the legacy two-call path so the page still works.
        if (snapErr && /not found|No object|declared|UBUS_STATUS_NOT_FOUND|Method not found/i.test(String(snapErr?.message || snapErr))) {
          const [st, ev] = await Promise.all([
            rpc.status(),
            rpc.events().catch(() => ({ events: [] as EventRow[] })),
          ])
          return { status: st, events: (ev && ev.events) || [] }
        }
        throw snapErr
      })
      if (id !== reqId.current) return  // superseded — leave state to the newer load
      setStatus(snap.status)
      setEvents(snap.events || [])
      setError(null)
    } catch (e: any) {
      if (id !== reqId.current) return
      setError(e?.message || String(e))
    } finally {
      if (id === reqId.current) setLoading(false)
    }
  }, [])

  useEffect(() => {
    refresh()
  }, [refresh])

  return (
    <div className="splify-react-root p-1 antialiased text-foreground">
      <div className="flex flex-col gap-4 md:flex-row">
        <nav className="flex shrink-0 flex-row gap-1 overflow-x-auto md:w-52 md:flex-col md:overflow-visible">
          {NAV.map(({ id, label, icon: Icon }) => {
            const active = tab === id
            return (
              <button key={id} onClick={() => setTab(id)}
                className={cn('flex items-center gap-2 whitespace-nowrap rounded-lg px-3 py-2 text-left text-sm transition',
                  active ? 'bg-primary font-medium text-primary-foreground' : 'text-muted-foreground hover:bg-primary/90 hover:text-primary-foreground')}>
                <Icon className="size-4 shrink-0" />{label}
              </button>
            )
          })}
        </nav>

        <div className="min-w-0 flex-1 space-y-4">
          <Suspense fallback={<div className="p-8 text-center text-muted-foreground animate-pulse">{t('Loading…')}</div>}>
            {tab === 'status' && (
              loading && !status ? (
                <div className="p-8 text-center text-muted-foreground animate-pulse">{t('Loading splify…')}</div>
              ) : error && !status ? (
                <div className="p-8 text-center text-destructive">{t('Error:')} {error}</div>
              ) : (
                <StatusDashboard
                  status={status} events={events}
                  busy={busy} setBusy={setBusy} refresh={refresh}
                />
              )
            )}
            {tab === 'wg' && <WgPanel />}
            {tab === 'api' && <ApiPanel />}
          </Suspense>
        </div>
      </div>
    </div>
  )
}
