import { useCallback, useEffect, useState } from 'react'
import { rpc, type Status, type EventRow } from '@/lib/rpc'
import StatusDashboard from '@/components/StatusDashboard'
import WgPanel from '@/components/WgPanel'
import ApiPanel from '@/components/ApiPanel'
import { cn } from '@/lib/utils'
import { Activity, Radio, ShieldCheck } from 'lucide-react'

type Tab = 'status' | 'wg' | 'api'

// Same left-rail navigation as the settings view — the two pages must read as
// one system, and Argon has no second-level horizontal tab row to mimic.
const NAV: { id: Tab; label: string; icon: React.ComponentType<{ className?: string }> }[] = [
  { id: 'status', label: 'Состояние', icon: Activity },
  { id: 'wg', label: 'AmneziaWG', icon: ShieldCheck },
  { id: 'api', label: 'Удалённое управление', icon: Radio },
]

export default function App() {
  const [tab, setTab] = useState<Tab>('status')
  const [status, setStatus] = useState<Status | null>(null)
  const [events, setEvents] = useState<EventRow[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState('')

  // Data loads once on mount and on demand via the "Обновить" button (and after
  // any action). There is deliberately NO background polling interval: a timer
  // firing every few seconds for the lifetime of the tab was both an annoyance
  // and a steady source of work that kept the long-lived view busy.
  const refresh = useCallback(async () => {
    try {
      const [st, ev] = await Promise.all([
        rpc.status(),
        rpc.events().catch(() => ({ events: [] as EventRow[] })),
      ])
      setStatus(st)
      setEvents((ev && ev.events) || [])
      setError(null)
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    refresh()
  }, [refresh])

  const wgIfaces = status ? (status.endpoints || []).map((e) => e.iface) : []

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
          {tab === 'status' && (
            loading && !status ? (
              <div className="p-8 text-center text-muted-foreground animate-pulse">Загрузка splify…</div>
            ) : error && !status ? (
              <div className="p-8 text-center text-destructive">Ошибка: {error}</div>
            ) : (
              <StatusDashboard
                status={status} events={events} wgIfaces={wgIfaces}
                busy={busy} setBusy={setBusy} refresh={refresh}
              />
            )
          )}
          {tab === 'wg' && <WgPanel />}
          {tab === 'api' && <ApiPanel />}
        </div>
      </div>
    </div>
  )
}
