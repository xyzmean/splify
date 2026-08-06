import { useMemo, useState } from 'react'
import type { Status, EventRow, Check, Sev, Live, LiveEndpoint } from '@/lib/rpc'
import { rpc } from '@/lib/rpc'
import type { Rate } from '@/lib/useSplifyData'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { SkeletonRows } from '@/components/ui/skeleton'
import { useConfirm } from '@/components/ui/confirm'
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { notify } from '@/lib/notify'
import { t, tCheck, tFix } from '@/lib/i18n'
import {
  ShieldCheck, AlertTriangle, Ban, Globe, RefreshCw, Play, RotateCw, Power,
  Download, Wrench, ArrowRight, Check as CheckIcon, X as XIcon, Minus, Rocket,
  Activity, Stethoscope, ExternalLink, ArrowDown, ArrowUp, HelpCircle,
  Network, ListChecks, History,
} from 'lucide-react'
import { fmtAge, fmtRate, fmtWhen, EVENT_META } from '@/lib/format'

// Severity → styling AND a human label. The raw enum (OK/WARN/FIXABLE/FAIL) used
// to be printed verbatim on the page; "FIXABLE" tells a router owner nothing
// about whether they have to do something.
const SEV: Record<Sev, { text: string; ring: string; badge: string; label: string }> = {
  OK:      { text: 'text-success',     ring: 'border-l-success',     badge: 'bg-success text-white border-transparent',     label: t('sev.OK') },
  WARN:    { text: 'text-warning',     ring: 'border-l-warning',     badge: 'bg-warning text-white border-transparent',     label: t('sev.WARN') },
  FIXABLE: { text: 'text-warning',     ring: 'border-l-warning',     badge: 'bg-warning/80 text-white border-transparent',  label: t('sev.FIXABLE') },
  FAIL:    { text: 'text-destructive', ring: 'border-l-destructive', badge: 'bg-destructive text-white border-transparent', label: t('sev.FAIL') },
}

// ── the one answer this page exists to give ──────────────────────────────────
// Plain language first, jargon second. `state` is vpn:<iface> | zapret |
// killswitch | wan (written by the failover daemon — see common.sh write_state).
function heroFor(state: string, mode: string, zapret: string) {
  if (/^vpn:/.test(state)) {
    const via = state.replace(/^vpn:/, '')
    return {
      icon: ShieldCheck,
      tone: 'text-success',
      title: t('Protected'),
      detail: mode === 'full'
        ? t('All traffic goes through the tunnel %s; the exceptions from your lists go direct.').replace('%s', via)
        : t('Blocked sites go through the tunnel %s. Everything else goes direct, at full speed.').replace('%s', via),
    }
  }
  if (state === 'zapret') {
    return {
      icon: AlertTriangle,
      tone: 'text-warning',
      title: t('No tunnel — DPI bypass is carrying it'),
      detail: t('Every tunnel is unreachable, so blocked sites are being opened by %s instead. That works, but it is slower and less reliable than a tunnel.').replace('%s', zapret || 'zapret'),
    }
  }
  if (state === 'killswitch') {
    return {
      icon: Ban,
      tone: 'text-destructive',
      title: t('Traffic blocked (kill switch)'),
      detail: t('No tunnel is available, and because the kill switch is on, traffic that should be protected is dropped instead of leaking to the open internet.'),
    }
  }
  return {
    icon: Globe,
    tone: 'text-muted-foreground',
    title: t('Protection is off'),
    detail: t('Everything goes straight to the internet through your provider — nothing is routed through a tunnel.'),
  }
}

function SevBadge({ sev }: { sev: Sev }) {
  return <Badge className={SEV[sev].badge}>{SEV[sev].label}</Badge>
}

function YesNo({ v }: { v: boolean }) {
  return v
    ? <CheckIcon className="size-4 text-success" />
    : <XIcon className="size-4 text-destructive" />
}

function HealthState({ health }: { health: string }) {
  if (health === 'ok' || health === 'OK') return <span className="flex items-center gap-1 text-success"><CheckIcon className="size-4" />{t('ок')}</span>
  if (health === 'idle') return <span className="flex items-center gap-1 text-muted-foreground"><Minus className="size-4" />{t('простой')}</span>
  if (health === 'FAIL') return <span className="flex items-center gap-1 text-destructive"><XIcon className="size-4" />FAIL</span>
  return <span className="text-muted-foreground">—</span>
}

// A term the page cannot avoid, with its explanation one hover away.
function Term({ children, hint }: { children: React.ReactNode; hint: string }) {
  return (
    <span className="inline-flex items-center gap-1" title={hint}>
      {children}
      <HelpCircle className="size-3 shrink-0 text-muted-foreground/60" />
    </span>
  )
}

// One content block. Every section on this page is one of these, so the corner
// radius, padding and header weight are identical everywhere — which is exactly
// what collapsible panels broke: their header kept the card radius while the body
// below it was square.
function Section({ title, icon: Icon, right, children }: {
  title: string
  icon: React.ComponentType<{ className?: string }>
  right?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between gap-3 space-y-0 px-5 pb-2 pt-3.5">
        <CardTitle className="flex items-center gap-2 text-[1.1rem] font-normal">
          <Icon className="size-4 text-muted-foreground" />{title}
        </CardTitle>
        {right && <span className="text-xs text-muted-foreground">{right}</span>}
      </CardHeader>
      <CardContent className="px-5 pb-4 pt-2">{children}</CardContent>
    </Card>
  )
}

// A tunnel row as displayed: live numbers merged with the firewall facts only the
// diagnostic sweep knows.
interface Row extends LiveEndpoint {
  zone?: string
  masq?: boolean
  forwarding?: boolean
  fwKnown: boolean
}

interface Props {
  live: Live | null
  status: Status | null
  events: EventRow[]
  rates: Record<string, Rate>
  overall: Sev
  diagError: string | null
  diagAge: number
  diagPending: boolean
  refresh: () => void
  refreshing: boolean
  afterAction: () => void
}

// Skeleton while the diagnostics half is in flight; an explicit message with a
// retry once it has actually failed. Never a skeleton that spins forever.
function Pending({ error, rows, onRetry }: { error: string | null; rows: number; onRetry: () => void }) {
  if (!error) return <SkeletonRows rows={rows} />
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
      <span className="text-destructive">{t('Diagnostics unavailable:')} {error}</span>
      <Button size="sm" variant="outline" onClick={onRetry}><RefreshCw className="size-4" />{t('Retry')}</Button>
    </div>
  )
}

export default function StatusDashboard(p: Props) {
  const { live, status, events, rates, overall } = p
  const [busy, setBusy] = useState('')
  const [ask, confirmDialog] = useConfirm()

  const d = useMemo(() => {
    const s = live?.summary
    const eps: LiveEndpoint[] = live?.endpoints || []
    const snapEps = status?.endpoints || []
    const rows: Row[] = eps.map((e) => {
      const se = snapEps.find((x) => x.iface === e.iface)
      return { ...e, zone: se?.zone, masq: se?.masq, forwarding: se?.forwarding, fwKnown: !!se }
    })
    const state = s?.state || ''
    const activeEp = rows.find((e) => state === 'vpn:' + e.iface)
    const lists = status?.lists || []
    const enabledLists = lists.filter((l) => l.enabled)
    return {
      s, rows, state, activeEp, lists, enabledLists,
      onlineTun: rows.filter((e) => e.present).length,
      okLists: enabledLists.filter((l) => l.ok).length,
      hero: heroFor(state, s?.mode || '', s?.zapret_version || ''),
      isOn: /^vpn:/.test(state) || state === 'zapret' || state === 'killswitch',
    }
  }, [live, status])

  // ⚡ Bolt: Split `totRx` and `totTx` into their own useMemo.
  // `rates` change every 4 seconds, so separating them prevents expensive
  // recalculations of lists filtering and endpoint mapping from running on every rate tick.
  const totals = useMemo(() => {
    if (!d.rows) return { totRx: 0, totTx: 0 }
    return {
      totRx: d.rows.reduce((a, e) => a + (rates[e.iface]?.rx || 0), 0),
      totTx: d.rows.reduce((a, e) => a + (rates[e.iface]?.tx || 0), 0),
    }
  }, [d.rows, rates])

  if (!d.s) {
    return (
      <div className="space-y-4">
        <Card className="border-l-4 border-l-muted"><CardContent className="p-5"><SkeletonRows rows={2} /></CardContent></Card>
        <Card><CardContent className="p-5"><SkeletonRows rows={3} /></CardContent></Card>
      </div>
    )
  }

  const { s, rows, hero, isOn, activeEp, lists, enabledLists, okLists, onlineTun } = d
  const { totRx, totTx } = totals
  const HeroIcon = hero.icon
  const checks = (status?.checks || []).filter((c) => c.severity !== 'OK')
  const haveDiag = !!status
  const firstRun = rows.length === 0

  async function run(action: string, toast?: string) {
    setBusy(action)
    try {
      const res = await rpc.action(action)
      notify((toast || action) + (res?.code !== 0 && res?.stdout ? ': ' + res.stdout : ''), res?.code === 0 ? 'info' : 'warning')
      p.afterAction()
    } catch (e: any) {
      notify(action + ': ' + (e?.message || e), 'error')
    } finally {
      setBusy('')
    }
  }

  async function fixFirewall(c: Check) {
    const m = /^([A-Za-z0-9_.-]+):/.exec(c.message || '')
    if (!m) return
    const iface = m[1]
    if (!await ask({
      title: t('Fix the firewall for %s?').replace('%s', iface),
      body: t('Create/repair the firewall zone for “%s” (accept-all + masquerading + lan↔tunnel↔wan forwarding) and reload the firewall?').replace('%s', iface),
      confirmLabel: t('Fix'), tone: 'default',
    })) return
    setBusy('fw_fix')
    try {
      const res = await rpc.action('fw_fix', iface)
      notify((res?.code === 0 ? t('Firewall fixed for %s') : t('Could not fix firewall for %s')).replace('%s', iface)
        + (res?.stdout ? ': ' + res.stdout : ''), res?.code === 0 ? 'info' : 'warning')
      p.afterAction()
    } catch (e: any) {
      notify(t('Firewall fix error:') + ' ' + (e?.message || e), 'error')
    } finally {
      setBusy('')
    }
  }

  function MaintBtn({ a, label, icon: Icon, toast }: {
    a: string; label: string; icon: React.ComponentType<{ className?: string }>; toast?: string
  }) {
    return (
      <Button size="sm" variant="outline" disabled={!!busy} onClick={() => run(a, toast)}>
        {busy === a ? <RefreshCw className="size-4 animate-spin" /> : <Icon className="size-4" />}{label}
      </Button>
    )
  }

  return (
    <div className="space-y-4">
      {confirmDialog}

      {/* ── 1. WHAT IS HAPPENING, in one sentence ─────────────────────── */}
      <Card className={cn('border-l-4', SEV[overall].ring)}>
        <CardContent className="p-5">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div className="flex min-w-[260px] flex-1 items-start gap-3">
              <div className={cn('flex size-11 shrink-0 items-center justify-center rounded-lg bg-muted', hero.tone)}>
                <HeroIcon className="size-6" />
              </div>
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <h2 className="text-base font-semibold tracking-tight">{hero.title}</h2>
                  {haveDiag && overall !== 'OK' && <SevBadge sev={overall} />}
                </div>
                <p className="mt-1 max-w-xl text-sm text-muted-foreground">{hero.detail}</p>
              </div>
            </div>
            <Button size="sm" disabled={!!busy}
              variant={isOn ? 'outline' : 'default'}
              className={isOn
                ? 'border-destructive text-destructive hover:bg-destructive/10'
                : 'bg-success text-white hover:bg-success/90'}
              onClick={async () => {
                if (isOn && !await ask({
                  title: t('Turn off protection?'),
                  body: t('Turn off split routing? All LAN traffic will go via WAN until the service re-enables it.'),
                  confirmLabel: t('Disable'),
                })) return
                run(isOn ? 'off' : 'on', isOn ? t('Split routing disabled') : t('Split routing enabled'))
              }}>
              {busy === 'on' || busy === 'off'
                ? <RefreshCw className="size-4 animate-spin" />
                : <Power className="size-4" />}
              {isOn ? t('Turn off protection') : t('Turn on protection')}
            </Button>
          </div>

          {/* Signs of life, on one line: speed now, which tunnel, how it routes. */}
          <div className="mt-4 flex flex-wrap items-center gap-x-6 gap-y-2 border-t pt-3 text-sm">
            <span className="flex items-center gap-1.5" title={t('Live speed through the tunnels')}>
              <ArrowDown className="size-4 text-success" /><b className="font-semibold">{fmtRate(totRx)}</b>
              <ArrowUp className="ml-2 size-4 text-info" /><b className="font-semibold">{fmtRate(totTx)}</b>
            </span>
            <span className="text-muted-foreground">
              {t('Tunnel')}: {activeEp ? <b className="text-foreground">{activeEp.iface}</b> : t('none')}
              {activeEp && <> · <Term hint={t('Handshake hint')}>{t('handshake')}</Term> {fmtAge(activeEp.handshake_age)}</>}
            </span>
            <span className="text-muted-foreground">
              {t('Mode')}: <b className="text-foreground">{t('mode.' + (s.mode || ''))}</b>
            </span>
            <span className="text-muted-foreground">
              <Term hint={t('Kill switch hint')}>{t('Kill switch')}</Term>{' '}
              <b className="text-foreground">{String(s.killswitch) === '1' ? t('on') : t('off')}</b>
            </span>
            <span className="text-muted-foreground">
              <Term hint={t('DPI bypass hint')}>{t('DPI bypass')}</Term>{' '}
              {s.zapret_version
                ? <b className={s.zapret_running ? 'text-foreground' : 'text-warning'}>{s.zapret_version}{s.zapret_running ? '' : ' (' + t('stopped') + ')'}</b>
                : <b className="text-muted-foreground/70">{t('not installed')}</b>}
            </span>
            {(s.fail_count ?? 0) > 0 && (
              <span className={SEV.WARN.text}>{t('Failures')}: <b>{s.fail_count}</b></span>
            )}
          </div>
        </CardContent>
      </Card>

      {/* ── 2. CONTROLS, immediately under the status they act on ──────── */}
      <div className="flex flex-wrap items-center gap-2 rounded-xl border bg-card/50 p-2 shadow-sm">
        <Button size="sm" disabled={!!busy} className="shadow-sm"
          title={t('Apply the splify configuration now')}
          onClick={() => run('apply', t('Configuration applied'))}>
          {busy === 'apply' ? <RefreshCw className="size-4 animate-spin" /> : <Play className="size-4" />}
          {t('Apply settings')}
        </Button>
        <Button size="sm" variant="outline" className="border-dashed bg-transparent hover:bg-muted"
          disabled={!!busy} onClick={p.refresh} title={t('Re-run diagnostics')}>
          <RefreshCw className={cn('size-4', p.refreshing && 'animate-spin')} />{t('Refresh')}
        </Button>
        <div className="flex-1" />
        <span className="flex items-center gap-1.5 px-1 text-xs text-muted-foreground">
          <span className={cn('size-1.5 rounded-full', p.refreshing || p.diagPending ? 'bg-warning' : 'bg-success')} />
          {p.diagPending
            ? t('Diagnostics: refreshing…')
            : p.diagAge >= 0
              ? t('Diagnostics: %s old').replace('%s', fmtAge(p.diagAge))
              : t('Diagnostics: loading…')}
        </span>
      </div>

      {/* ── notices ────────────────────────────────────────────────────── */}
      {s.update_available && (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-primary/20 bg-primary/5 px-4 py-2 text-sm text-primary">
          <span className="flex items-center gap-2">
            <Download className="size-4" />{t('Update available:')} <b className="font-medium">{s.update_version}</b>
          </span>
          <Button size="sm" variant="ghost" className="h-7 px-2 hover:bg-primary/10" disabled={!!busy}
            onClick={async () => {
              if (!await ask({
                title: t('Install update now?'),
                body: t('Install update now? This will download and install the latest version in the background. The router might momentarily disconnect.'),
                confirmLabel: t('Install'), tone: 'default',
              })) return
              run('update', t('Update started in the background'))
            }}>
            {busy === 'update' ? <RefreshCw className="mr-1.5 size-3 animate-spin" /> : null}{t('Install')}
          </Button>
        </div>
      )}

      {firstRun && (
        <Card className="border border-dashed border-warning bg-warning/5">
          <CardContent className="p-5">
            <h3 className="mb-2 flex items-center gap-2 font-semibold"><Rocket className="size-4 text-warning" />{t("Let's connect the first tunnel")}</h3>
            <p className="mb-3 text-sm text-muted-foreground">{t('No tunnels yet, so all LAN traffic currently goes through plain WAN.')}</p>
            <ol className="ml-5 list-decimal space-y-1.5 text-sm">
              <li>Создайте интерфейс WireGuard/AmneziaWG в <a className="text-primary underline-offset-4 hover:underline" href={window.L?.url('admin/network/network')}>Сеть → Интерфейсы</a> — splify не хранит ключи и не создаёт туннели сам.</li>
              <li>Добавьте его в <a className="text-primary underline-offset-4 hover:underline" href={window.L?.url('admin/services/splify/settings')}>Дополнительно → Туннели</a> с приоритетом и нажмите «Сохранить и применить».</li>
              <li>Если появится замечание про firewall — нажмите «Исправить» в блоке «Что требует внимания».</li>
            </ol>
          </CardContent>
        </Card>
      )}

      {/* ── 3. WHERE TRAFFIC GOES ──────────────────────────────────────── */}
      <Card>
        <CardHeader className="px-5 pb-2 pt-3.5">
          <CardTitle className="flex items-center gap-2 text-[1.1rem] font-normal">
            <Activity className="size-4 text-muted-foreground" />{t('Where your traffic goes')}
          </CardTitle>
        </CardHeader>
        <CardContent className="px-5 pb-4 pt-2">
          <Chain live={live!} rates={rates} />
        </CardContent>
      </Card>

      {/* ── 4. WHAT NEEDS ATTENTION ────────────────────────────────────── */}
      <Card className={checks.length ? cn('border-l-4', SEV[overall].ring) : undefined}>
        <CardHeader className="px-5 pb-2 pt-3.5">
          <CardTitle className="flex items-center gap-2 text-[1.1rem] font-normal">
            <Stethoscope className="size-4 text-muted-foreground" />{t('What needs attention')}
            {haveDiag && checks.length > 0 && <span className="text-sm text-muted-foreground">· {checks.length}</span>}
          </CardTitle>
        </CardHeader>
        <CardContent className="px-5 pb-4 pt-2">
          {!haveDiag ? <Pending error={p.diagPending ? null : p.diagError} rows={2} onRetry={p.refresh} /> : checks.length === 0 ? (
            <p className="flex items-center gap-2 text-sm font-medium text-success">
              <CheckIcon className="size-4" />{t('Everything is in order.')}
            </p>
          ) : (
            <div className="space-y-2">
              {checks.map((c) => (
                <div key={c.category + ':' + c.message}
                  className={cn('flex flex-wrap items-center gap-2 rounded-md border-l-4 bg-muted/40 p-2.5 text-sm', SEV[c.severity].ring)}>
                  <SevBadge sev={c.severity} />
                  <div className="min-w-[200px] flex-1">
                    <div>{tCheck(c.message)}</div>
                    {c.fix && <div className="mt-0.5 text-muted-foreground">→ {tFix(c.fix)}</div>}
                  </div>
                  {c.category === 'firewall' && !/in the shared |device wildcard|non-tunnel networks/.test(c.message) && /^([A-Za-z0-9_.-]+):/.test(c.message) && (
                    <Button size="sm" variant="outline" className="border-primary text-primary" disabled={!!busy} onClick={() => fixFirewall(c)}>
                      {busy === 'fw_fix' ? <RefreshCw className="size-4 animate-spin" /> : <Wrench className="size-4" />}{t('Fix')}
                    </Button>
                  )}
                  {c.category === 'firewall' && (
                    <Button size="sm" variant="ghost" asChild>
                      <a href={window.L?.url('admin/network/firewall')}><ExternalLink className="size-4" />Firewall</a>
                    </Button>
                  )}
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      <Section title={t('Maintenance')} icon={Wrench}
        right={t('lists refresh themselves daily')}>
        <div className="flex flex-wrap items-center gap-2">
          <MaintBtn a="restart" label={t('Restart service')} icon={RotateCw} toast={t('Service restarted')} />
          <MaintBtn a="update_ipsum" label={t('Refresh blocked-IP list')} icon={Download} toast={t('ipsum updated')} />
          <MaintBtn a="update_ru" label={t('Refresh RU list')} icon={Download} toast={t('ru/cn updated')} />
          <MaintBtn a="update_domains" label={t('Refresh domain list')} icon={Download} toast={t('domains updated')} />
          <div className="flex-1" />
          <Button size="sm" variant="destructive" disabled={!!busy}
            onClick={async () => {
              if (!await ask({
                title: t('Emergency disable'),
                body: t('Disable split routing now? All LAN traffic will exit via WAN until the service re-enables it (or you stop it).'),
                confirmLabel: t('Emergency disable'),
              })) return
              run('disable', t('Split routing disabled'))
            }}>
            {busy === 'disable' ? <RefreshCw className="size-4 animate-spin" /> : <Power className="size-4" />}
            {t('Emergency disable')}
          </Button>
        </div>
        <p className="mt-2 text-xs text-muted-foreground">{t('Lists refresh themselves daily; these buttons are for when you do not want to wait.')}</p>
      </Section>

      {/* ── 5. DETAILS, for whoever is debugging ───────────────────────── */}
      <Section title={t('Tunnels')} icon={Network}
        right={`${onlineTun}/${rows.length} ${t('online')}`}>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>{t('Tunnel')}</TableHead>
              <TableHead title={t('Priority hint')}>{t('Prio')}</TableHead>
              <TableHead title={t('Handshake hint')}>{t('Handshake')}</TableHead>
              <TableHead>{t('Traffic')}</TableHead>
              <TableHead>{t('Health')}</TableHead>
              <TableHead className="hidden lg:table-cell" title={t('Zone hint')}>{t('Zone')}</TableHead>
              <TableHead className="hidden lg:table-cell" title={t('Masquerade (masq) hides LAN behind the tunnel IP')}>{t('Masq')}</TableHead>
              <TableHead className="hidden lg:table-cell" title={t('Forwarding lan → tunnel is required for traffic to reach the tunnel')}>{t('LAN fwd')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((e) => {
              const r = rates[e.iface] || { rx: 0, tx: 0 }
              return (
                <TableRow key={e.iface}>
                  <TableCell className="font-medium">{e.present ? e.iface : <span className="text-destructive">{e.iface} ({t('absent')})</span>}</TableCell>
                  <TableCell>{e.priority || '—'}</TableCell>
                  <TableCell>{e.present ? fmtAge(e.handshake_age) : '—'}</TableCell>
                  <TableCell className="whitespace-nowrap">{e.present ? <><span className="text-success">↓{fmtRate(r.rx)}</span> <span className="text-info">↑{fmtRate(r.tx)}</span></> : '—'}</TableCell>
                  <TableCell><HealthState health={e.health} /></TableCell>
                  <TableCell className="hidden lg:table-cell">{!e.fwKnown ? <span className="text-muted-foreground">…</span> : e.zone || <span className="text-destructive">{t('none')}</span>}</TableCell>
                  <TableCell className="hidden lg:table-cell">{!e.fwKnown ? <span className="text-muted-foreground">…</span> : <YesNo v={!!e.masq} />}</TableCell>
                  <TableCell className="hidden lg:table-cell">{!e.fwKnown ? <span className="text-muted-foreground">…</span> : <YesNo v={!!e.forwarding} />}</TableCell>
                </TableRow>
              )
            })}
          </TableBody>
        </Table>
        <p className="mt-2 text-xs text-muted-foreground">{t('Failover hint')}.</p>
      </Section>

      <Section title={t('Lists')} icon={ListChecks}
        right={haveDiag ? `${okLists}/${enabledLists.length} ${t('in order')}` : undefined}>
        {!haveDiag ? <Pending error={p.diagPending ? null : p.diagError} rows={3} onRetry={p.refresh} /> : (
          <>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('List')}</TableHead><TableHead>{t('Entries')}</TableHead>
                  <TableHead>{t('Min')}</TableHead><TableHead>{t('Age')}</TableHead><TableHead>{t('State')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {lists.map((l) => (
                  <TableRow key={l.name}>
                    <TableCell className="whitespace-nowrap"><span title={t('list.hint.' + l.name)}>{t('list.' + l.name)}</span></TableCell>
                    <TableCell>{l.enabled ? l.count : <span className="text-muted-foreground">({t('off')})</span>}</TableCell>
                    <TableCell>{l.min}</TableCell>
                    <TableCell>{fmtAge(l.age)}</TableCell>
                    <TableCell>{l.enabled ? <YesNo v={l.ok} /> : '—'}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            <p className="mt-2 text-xs text-muted-foreground">{t('Lists explainer')}</p>
          </>
        )}
      </Section>

      <Section title={t('Event history')} icon={History}
        right={events.length ? t('last: %s').replace('%s', fmtWhen(events[0].ts)) : undefined}>
        {!haveDiag ? <Pending error={p.diagPending ? null : p.diagError} rows={2} onRetry={p.refresh} /> : events.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t('No failover events recorded yet.')}</p>
        ) : (
          <Table>
            <TableBody>
              {events.slice(0, 50).map((ev) => {
                const m = EVENT_META[ev.kind] || { i: '•', cls: 'text-muted-foreground', ru: ev.kind }
                const pathStr = ev.from && ev.to ? `${ev.from} → ${ev.to}` : ev.to || ev.from || ''
                return (
                  <TableRow key={ev.ts + ':' + ev.kind}>
                    <TableCell className={cn('whitespace-nowrap font-semibold', m.cls)}>{m.i} {m.ru}</TableCell>
                    <TableCell className="whitespace-nowrap">{pathStr}</TableCell>
                    <TableCell className="text-muted-foreground">{ev.reason || ''}</TableCell>
                    <TableCell className="whitespace-nowrap text-right text-muted-foreground">{fmtWhen(ev.ts)}</TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        )}
      </Section>
    </div>
  )
}

// ── traffic classes ──────────────────────────────────────────────────────────
// Three classes side by side, because that is what actually happens at once:
// while the tunnel carries blocked sites, RU traffic goes direct AND zapret works
// on the rest. Each card now states WHY its traffic goes where it goes — the bare
// destination ("wan", "zapret") meant nothing to anyone who did not build this.
type Tone = 'success' | 'warning' | 'destructive' | 'neutral'

const TONE: Record<Tone, string> = {
  success: 'bg-success/10 border-success/30 text-success',
  warning: 'bg-warning/10 border-warning/30 text-warning',
  destructive: 'bg-destructive/10 border-destructive/30 text-destructive',
  neutral: 'bg-muted border-border text-muted-foreground',
}

function PathCard({ title, what, dest, sub, tone }: {
  title: string; what: string; dest: React.ReactNode; sub?: React.ReactNode; tone: Tone
}) {
  return (
    <div className="flex flex-col gap-2 rounded-xl border bg-card p-4 shadow-sm">
      <div>
        <div className="text-sm font-medium">{title}</div>
        <div className="mt-0.5 text-xs text-muted-foreground">{what}</div>
      </div>
      <div className="mt-auto flex items-center gap-2">
        <ArrowRight className="size-4 shrink-0 text-muted-foreground/50" />
        <div className={cn('flex-1 rounded-lg border px-3 py-2 text-center', TONE[tone])}>
          <div className="text-sm font-semibold">{dest}</div>
          {sub != null && sub !== '' && <div className="mt-0.5 text-[11px] opacity-80">{sub}</div>}
        </div>
      </div>
    </div>
  )
}

function Chain({ live, rates }: { live: Live; rates: Record<string, Rate> }) {
  const s = live.summary
  const state = s.state || ''
  const mode = s.mode || ''
  const activeEp = (live.endpoints || []).find((e) => state === 'vpn:' + e.iface)
  const zapretInstalled = !!s.zapret_version
  const zapretLabel = s.zapret_version || 'zapret'
  const killed = state === 'killswitch'
  const isVpn = !!activeEp
  const r = activeEp ? (rates[activeEp.iface] || { rx: 0, tx: 0 }) : { rx: 0, tx: 0 }
  const viaTunnel = (iface: string) => t('through %s').replace('%s', iface)
  const vpnSub = activeEp
    ? <span className="whitespace-nowrap"><span className="text-success">↓{fmtRate(r.rx)}</span> <span className="text-info">↑{fmtRate(r.tx)}</span></span>
    : undefined

  // ① blocked sites (the ipsum list)
  let c1: { dest: React.ReactNode; sub?: React.ReactNode; tone: Tone }
  if (killed) c1 = { dest: t('Blocked — kill switch'), tone: 'destructive' }
  else if (isVpn) c1 = { dest: viaTunnel(activeEp!.iface), sub: vpnSub, tone: 'success' }
  else if (zapretInstalled) c1 = { dest: zapretLabel, sub: t('DPI bypass (zapret)'), tone: 'warning' }
  else c1 = { dest: t('Direct (WAN)'), sub: t('may be unreachable'), tone: 'destructive' }

  // ② RU / neutral — always direct: that is exactly what the ru/cn list is for
  const c2: { dest: React.ReactNode; sub?: React.ReactNode; tone: Tone } = killed
    ? { dest: t('Blocked — kill switch'), tone: 'destructive' }
    : { dest: t('Direct (WAN)'), sub: t('full provider speed'), tone: 'success' }

  // ③ everything else
  let c3: { dest: React.ReactNode; sub?: React.ReactNode; tone: Tone }
  if (killed) c3 = { dest: t('Blocked — kill switch'), tone: 'destructive' }
  else if (mode === 'full' && isVpn) c3 = { dest: viaTunnel(activeEp!.iface), sub: t('via VPN'), tone: 'success' }
  else if (zapretInstalled) c3 = { dest: zapretLabel, sub: t('DPI bypass (zapret)'), tone: 'success' }
  else c3 = { dest: t('Direct (WAN)'), sub: t('full provider speed'), tone: 'neutral' }

  return (
    <div className="space-y-2">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <PathCard title={t('Blocked sites')} what={t('addresses from the blocked-IP list')} {...c1} />
        <PathCard title={t('Russian sites')} what={t('from the RU/CN list — banks, government, local services')} {...c2} />
        <PathCard title={t('Everything else')}
          what={mode === 'full' ? t('in full mode this rides the tunnel too') : t('ordinary sites and apps')} {...c3} />
      </div>
      <p className="text-center text-xs text-muted-foreground">
        {t('Your devices')} → {s.lan_iface || 'LAN'} → {t('Internet')}
      </p>
    </div>
  )
}
