import { useState } from 'react'
import StatusDashboard from '@/components/StatusDashboard'
import WgPanel from '@/components/WgPanel'
import ApiPanel from '@/components/ApiPanel'
// sing-box tab is hidden — the backend (SingboxPanel.tsx + singbox_* rpc methods)
// stays in place so the feature can be re-enabled when it is finished.
// import SingboxPanel from '@/components/SingboxPanel'
import { useSplifyData } from '@/lib/useSplifyData'
import { cn } from '@/lib/utils'
import { t } from '@/lib/i18n'
import { Activity, Radio, ShieldCheck, RefreshCw } from 'lucide-react'
import { Button } from '@/components/ui/button'

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
  // One data layer for the whole view: a cheap live poll plus cached
  // diagnostics. See lib/useSplifyData.ts for why the read path is split.
  const data = useSplifyData()

  return (
    <div className="splify-react-root p-1 antialiased text-foreground">
      <div className="flex flex-col gap-4 md:flex-row">
        <nav className="flex shrink-0 flex-row gap-1 overflow-x-auto md:w-52 md:flex-col md:overflow-visible">
          {NAV.map(({ id, label, icon: Icon }) => {
            const active = tab === id
            return (
              <button key={id} onClick={() => setTab(id)}
                className={cn('flex items-center gap-2 whitespace-nowrap rounded-lg px-3 py-2 text-left text-sm transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1',
                  active ? 'bg-primary font-medium text-primary-foreground' : 'text-muted-foreground hover:bg-primary/90 hover:text-primary-foreground')}>
                <Icon className="size-4 shrink-0" />{label}
              </button>
            )
          })}
        </nav>

        <div className="min-w-0 flex-1 space-y-4">
          {tab === 'status' && (
            <>
              {/* A failed poll must never blank a working page: the dashboard
                  keeps rendering the last good data and the error rides above
                  it with a retry, instead of replacing everything. */}
              {data.error && (
                <div className="flex items-center justify-between gap-3 rounded-lg border border-destructive/50 px-3 py-2 text-sm text-destructive">
                  <span className="min-w-0 truncate">{t('Error:')} {data.error}</span>
                  <Button size="sm" variant="outline" onClick={data.refresh}>
                    <RefreshCw className={cn('size-4', data.refreshing && 'animate-spin')} />{t('Retry')}
                  </Button>
                </div>
              )}
              <StatusDashboard
                live={data.live} status={data.status} events={data.events}
                rates={data.rates} overall={data.overall}
                diagError={data.diagError}
                diagAge={data.diagAge} diagPending={data.diagPending}
                refresh={data.refresh} refreshing={data.refreshing}
                afterAction={data.afterAction}
              />
            </>
          )}
          {tab === 'wg' && <WgPanel />}
          {tab === 'api' && <ApiPanel />}
        </div>
      </div>
    </div>
  )
}
