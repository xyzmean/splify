import { useCallback, useEffect, useRef, useState } from 'react'
import { rpc, type Status, type EventRow } from '@/lib/rpc'
import StatusDashboard from '@/components/StatusDashboard'
import WgPanel from '@/components/WgPanel'
import ApiPanel from '@/components/ApiPanel'

type Tab = 'status' | 'wg' | 'api'
const POLL_MS = 8000

export default function App() {
  const [tab, setTab] = useState<Tab>('status')
  const [status, setStatus] = useState<Status | null>(null)
  const [events, setEvents] = useState<EventRow[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState('')
  const [live, setLive] = useState(true)
  const timer = useRef<number | null>(null)

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

  useEffect(() => {
    if (live && tab === 'status') {
      timer.current = window.setInterval(refresh, POLL_MS)
      return () => { if (timer.current) window.clearInterval(timer.current) }
    }
  }, [live, tab, refresh])

  const wgIfaces = status ? (status.endpoints || []).map((e) => e.iface) : []

  return (
    <div className="max-w-5xl mx-auto p-1 font-sans antialiased text-slate-900 dark:text-slate-100">
      <div className="flex items-center gap-1 border-b border-slate-200 dark:border-slate-800 mb-5">
        <TabBtn id="status" cur={tab} set={setTab}>Состояние</TabBtn>
        <TabBtn id="wg" cur={tab} set={setTab}>AmneziaWG</TabBtn>
        <TabBtn id="api" cur={tab} set={setTab}>Удалённое управление</TabBtn>
      </div>

      {tab === 'status' && (
        loading && !status ? (
          <div className="p-8 text-center text-slate-500 animate-pulse">Загрузка splify…</div>
        ) : error && !status ? (
          <div className="p-8 text-center text-rose-500">Ошибка: {error}</div>
        ) : (
          <StatusDashboard
            status={status} events={events} wgIfaces={wgIfaces}
            busy={busy} setBusy={setBusy} refresh={refresh}
            live={live} toggleLive={() => setLive((v) => !v)}
          />
        )
      )}
      {tab === 'wg' && <WgPanel />}
      {tab === 'api' && <ApiPanel />}
    </div>
  )
}

function TabBtn({ id, cur, set, children }: { id: Tab; cur: Tab; set: (t: Tab) => void; children: React.ReactNode }) {
  const active = cur === id
  return (
    <button
      onClick={() => set(id)}
      className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition ${
        active
          ? 'border-blue-500 text-blue-600 dark:text-blue-400'
          : 'border-transparent opacity-70 hover:opacity-100'
      }`}>
      {children}
    </button>
  )
}
