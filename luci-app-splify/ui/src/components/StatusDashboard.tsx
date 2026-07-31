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
import { t } from '@/lib/i18n'
import {
  ShieldCheck, AlertTriangle, Ban, Globe, RefreshCw, Play, RotateCw, Power,
  Download, Wrench, ArrowRight, Check as CheckIcon, X as XIcon, Minus, Rocket,
  Activity, ListChecks, Network, History, Stethoscope, ExternalLink,
} from 'lucide-react'
import {
  fmtAge, fmtRate, fmtWhen, pathLabel, EVENT_META,
} from '@/lib/format'

// Severity → semantic styling. One source of truth so the hero, badges and
// diagnostics all read identically.
const SEV: Record<Sev, { text: string; ring: string; badge: string }> = {
  OK:      { text: 'text-success',     ring: 'border-l-success',     badge: 'bg-success text-white border-transparent' },
  WARN:    { text: 'text-warning',     ring: 'border-l-warning',     badge: 'bg-warning text-white border-transparent' },
  FIXABLE: { text: 'text-warning',     ring: 'border-l-warning',     badge: 'bg-warning/80 text-white border-transparent' },
  FAIL:    { text: 'text-destructive', ring: 'border-l-destructive', badge: 'bg-destructive text-white border-transparent' },
}

function stateIcon(state: string) {
  if (/^vpn:/.test(state)) return ShieldCheck
  if (state === 'zapret') return AlertTriangle
  if (state === 'killswitch') return Ban
  return Globe
}

function SevBadge({ sev }: { sev: Sev }) {
  return <Badge className={SEV[sev].badge}>{sev}</Badge>
}

function YesNo({ v }: { v: boolean }) {
  return v
    ? <CheckIcon className="size-4 text-success" />
    : <XIcon className="size-4 text-destructive" />
}

// Mirrors YesNo: an icon carries the meaning, not colour alone.
function HealthState({ health }: { health: string }) {
  if (health === 'ok' || health === 'OK') return <span className="flex items-center gap-1 text-success"><CheckIcon className="size-4" />{t('ок')}</span>
  if (health === 'idle') return <span className="flex items-center gap-1 text-muted-foreground"><Minus className="size-4" />{t('простой')}</span>
  if (health === 'FAIL') return <span className="flex items-center gap-1 text-destructive"><XIcon className="size-4" />FAIL</span>
  return <span className="text-muted-foreground">—</span>
}

// A tunnel row as displayed: live numbers (state, handshake, traffic) merged
// with the firewall facts that only the diagnostic sweep knows.
interface Row extends LiveEndpoint {
  zone?: string
  masq?: boolean
  forwarding?: boolean
  /** false until the diagnostics arrive — the zone columns show a dash, not a lie */
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

// Placeholder for a section fed by the diagnostics half: skeleton while it is on
// its way, an explicit message with a retry once it has actually failed. Never a
// skeleton that spins forever — that lies about what is happening.
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

  // Everything derived, in one place. Recomputed when live/status/rates change —
  // i.e. once per poll — never on an unrelated re-render (a spinner starting).
  const d = useMemo(() => {
    const s = live?.summary
    const eps: LiveEndpoint[] = live?.endpoints || []
    const snapEps = status?.endpoints || []
    const rows: Row[] = eps.map((e) => {
      const se = snapEps.find((x) => x.iface === e.iface)
      return {
        ...e,
        zone: se?.zone, masq: se?.masq, forwarding: se?.forwarding,
        fwKnown: !!se,
      }
    })
    const state = s?.state || ''
    const activeEp = rows.find((e) => state === 'vpn:' + e.iface)
    const totRx = rows.reduce((a, e) => a + (rates[e.iface]?.rx || 0), 0)
    const totTx = rows.reduce((a, e) => a + (rates[e.iface]?.tx || 0), 0)
    const onlineTun = rows.filter((e) => e.present).length
    const lists = status?.lists || []
    const enabledLists = lists.filter((l) => l.enabled)
    const okLists = enabledLists.filter((l) => l.ok).length
    return {
      s, rows, state, path: pathLabel(state), HeroIcon: stateIcon(state),
      isOn: /^vpn:/.test(state) || state === 'zapret' || state === 'killswitch',
      activeEp, totRx, totTx, onlineTun, lists, enabledLists, okLists,
    }
  }, [live, status, rates])

  // Nothing at all yet (first paint before the first live reply lands, ~0.2s).
  if (!d.s) {
    return (
      <div className="space-y-4">
        <Card className="border-l-4 border-l-muted"><CardContent className="p-4"><SkeletonRows rows={2} /></CardContent></Card>
        <Card><CardContent className="p-4"><SkeletonRows rows={4} /></CardContent></Card>
      </div>
    )
  }

  const { s, rows, path, HeroIcon, isOn, activeEp, totRx, totTx, onlineTun, lists, enabledLists, okLists } = d

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
    const ok = await ask({
      title: t('Fix the firewall for %s?').replace('%s', iface),
      body: t('Create/repair the firewall zone for “%s” (accept-all + masquerading + lan↔tunnel↔wan forwarding) and reload the firewall?').replace('%s', iface),
      confirmLabel: t('Fix'),
      tone: 'default',
    })
    if (!ok) return
    setBusy('fw_fix')
    try {
      const res = await rpc.action('fw_fix', iface)
      const okMsg = t('Firewall fixed for %s').replace('%s', iface)
      const errMsg = t('Could not fix firewall for %s').replace('%s', iface)
      notify((res?.code === 0 ? okMsg : errMsg) + (res?.stdout ? ': ' + res.stdout : ''), res?.code === 0 ? 'info' : 'warning')
      p.afterAction()
    } catch (e: any) {
      notify(t('Firewall fix error:') + ' ' + (e?.message || e), 'error')
    } finally {
      setBusy('')
    }
  }

  // A toolbar action button that shows a spinner while its action is running.
  function ActBtn({ a, label, icon: Icon, variant = 'outline', toast, className, title }: {
    a: string; label: string; icon: React.ComponentType<{ className?: string }>
    variant?: 'default' | 'outline' | 'secondary' | 'destructive' | 'ghost'
    toast?: string; className?: string; title?: string
  }) {
    return (
      <Button size="sm" variant={variant} className={className} disabled={!!busy} title={title}
        onClick={() => run(a, toast)}>
        {busy === a ? <RefreshCw className="size-4 animate-spin" /> : <Icon className="size-4" />}
        {label}
      </Button>
    )
  }

  const checks = (status?.checks || []).filter((c) => c.severity !== 'OK')
  const haveDiag = !!status
  const firstRun = rows.length === 0

  return (
    <div className="space-y-4">
      {confirmDialog}

      {/* ── Hero + KPI (compact single-row header) ─────────────── */}
      <Card className={cn('border-l-4', SEV[overall].ring)}>
        <CardContent className="flex flex-wrap items-center gap-4 p-4">
          <div className="flex min-w-[240px] flex-1 items-center gap-3">
            <div className={cn('flex size-9 shrink-0 items-center justify-center rounded-lg bg-muted', SEV[overall].text)}>
              <HeroIcon className="size-5" />
            </div>
            <div className="min-w-0">
              <div className="truncate text-sm font-semibold tracking-tight">{path.title}</div>
              <div className="mt-0.5 text-xs text-muted-foreground">
                {t('Mode')} <b className="text-foreground">{s.mode || '?'}</b> · {t('Kill switch')} <b className="text-foreground">{String(s.killswitch) === '1' || s.killswitch === 1 ? t('on') : t('off')}</b>
                {' · DPI: '}{s.zapret_version
                  ? <b className={s.zapret_running ? 'text-foreground' : 'text-warning'}>{s.zapret_version}{s.zapret_running ? '' : ' (' + t('stopped') + ')'}</b>
                  : <b className="text-muted-foreground/70">{t('none')}</b>}
              </div>
            </div>
          </div>

          <div className="flex flex-wrap items-center gap-x-5 gap-y-1">
            <MiniStat label={t('Tunnel')} value={activeEp ? activeEp.iface : '—'}
              sub={activeEp ? t('handshake') + ' ' + fmtAge(activeEp.handshake_age) : undefined} />
            <MiniStat label={t('RX')} value={fmtRate(totRx)} />
            <MiniStat label={t('TX')} value={fmtRate(totTx)} />
            <MiniStat label={t('Failures')} value={String(s.fail_count ?? '?')} tone={(s.fail_count ?? 0) > 0 ? SEV.WARN.text : undefined} />
            <MiniStat label={t('Lists OK')}
              value={haveDiag ? `${okLists}/${enabledLists.length}` : '…'}
              tone={haveDiag && okLists < enabledLists.length ? SEV.WARN.text : undefined} />
          </div>

          <div className="flex items-center gap-2">
            <SevBadge sev={overall} />
            <Button size="sm" disabled={!!busy}
              variant={isOn ? 'outline' : 'default'}
              className={isOn
                ? 'border-destructive text-destructive hover:bg-destructive/10'
                : 'bg-success text-white hover:bg-success/90'}
              onClick={async () => {
                if (isOn && !await ask({
                  title: t('Turn off split routing?'),
                  body: t('Turn off split routing? All LAN traffic will go via WAN until the service re-enables it.'),
                  confirmLabel: t('Disable'),
                })) return
                run(isOn ? 'off' : 'on', isOn ? t('Split routing disabled') : t('Split routing enabled'))
              }}>
              {busy === 'on' || busy === 'off'
                ? <RefreshCw className="size-4 animate-spin" />
                : <Power className="size-4" />}
              {isOn ? t('Disable') : t('Enable')}
            </Button>
          </div>
        </CardContent>
      </Card>

      {/* ── Toolbar (carded, so it reads as one control block) ── */}
      <div className="flex flex-wrap items-center gap-2 rounded-xl border bg-card/50 p-2 shadow-sm">
        <Button size="sm" variant="outline" className="border-dashed bg-transparent hover:bg-muted"
          disabled={!!busy} onClick={p.refresh} title={t('Re-run diagnostics')}>
          <RefreshCw className={cn('size-4', p.refreshing && 'animate-spin')} />{t('Refresh')}
        </Button>
        <ActBtn a="apply" label={t('Apply')} icon={Play} variant="default" className="shadow-sm"
          toast={t('Configuration applied')} title={t('Apply the splify configuration now')} />
        <ActBtn a="restart" label={t('Restart')} icon={RotateCw} variant="secondary" className="shadow-sm"
          toast={t('Service restarted')} title={t('Restart the splify service')} />

        <div className="ml-2 flex items-center gap-1 rounded-lg bg-muted/50 p-1">
          <span className="px-2 text-xs font-medium text-muted-foreground">{t('Lists')}</span>
          <ActBtn a="update_ipsum" label="ipsum" icon={Download} variant="ghost" className="h-7 px-2 text-xs"
            toast={t('ipsum updated')} title={t('Update the ipsum (blocked IP) list')} />
          <ActBtn a="update_ru" label="ru/cn" icon={Download} variant="ghost" className="h-7 px-2 text-xs"
            toast={t('ru/cn updated')} title={t('Update the ru/cn (direct) list')} />
          <ActBtn a="update_domains" label={t('domains')} icon={Download} variant="ghost" className="h-7 px-2 text-xs"
            toast={t('domains updated')} title={t('Update the VPN domains list')} />
        </div>

        <div className="flex-1" />

        {/* Where the numbers come from, in one glance: live values tick every few
            seconds, diagnostics are a cached sweep with a real age. */}
        <span className="hidden items-center gap-1.5 px-1 text-xs text-muted-foreground sm:flex">
          <span className={cn('size-1.5 rounded-full', p.refreshing || p.diagPending ? 'bg-warning' : 'bg-success')} />
          {p.diagPending
            ? t('Diagnostics: refreshing…')
            : p.diagAge >= 0
              ? t('Diagnostics: %s old').replace('%s', fmtAge(p.diagAge))
              : t('Diagnostics: loading…')}
        </span>

        <Button size="sm" variant="destructive" className="shadow-sm" disabled={!!busy}
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

      {/* ── Update notification ──────────────────────────────── */}
      {s.update_available && (
        <div className="flex items-center justify-between rounded-lg border border-primary/20 bg-primary/5 px-3 py-1.5 text-sm text-primary">
          <div className="flex items-center gap-2">
            <Download className="size-4" />
            <span>{t('Update available:')} <b className="font-medium">{s.update_version}</b></span>
          </div>
          <Button size="sm" variant="ghost" className="h-7 px-2 hover:bg-primary/10" disabled={!!busy}
            onClick={async () => {
              if (!await ask({
                title: t('Install update now?'),
                body: t('Install update now? This will download and install the latest version in the background. The router might momentarily disconnect.'),
                confirmLabel: t('Install'),
                tone: 'default',
              })) return
              run('update', t('Update started in the background'))
            }}>
            {busy === 'update' ? <RefreshCw className="mr-1.5 size-3 animate-spin" /> : null}
            {t('Install')}
          </Button>
        </div>
      )}

      {/* ── First-run helper ─────────────────────────────────── */}
      {firstRun && (
        <Card className="border border-dashed border-warning bg-warning/5">
          <CardContent className="p-5">
            <h4 className="mb-2 flex items-center gap-2 font-semibold"><Rocket className="size-4 text-warning" />{t("Let's connect the first tunnel")}</h4>
            <p className="mb-2 text-sm text-muted-foreground">{t('No tunnels yet, so all LAN traffic currently goes through plain WAN.')}</p>
            <ol className="ml-5 list-decimal space-y-1 text-sm">
              <li>Создайте интерфейс WireGuard/AmneziaWG в <a className="text-primary underline-offset-4 hover:underline" href={window.L?.url('admin/network/network')}>Сеть → Интерфейсы</a> (splify не управляет ключами).</li>
              <li>Добавьте его на вкладке <a className="text-primary underline-offset-4 hover:underline" href={window.L?.url('admin/services/splify/settings')}>Дополнительно</a> в «Туннели» с приоритетом, затем «Сохранить и применить».</li>
              <li>Поместите туннель в firewall-зону (masq вкл) и разрешите форвардинг lan → зона — или нажмите «Исправить» на находке firewall ниже.</li>
            </ol>
          </CardContent>
        </Card>
      )}

      {/* ── Routing chain (full width) ───────────────────────── */}
      <Section title={t('Traffic path')} icon={Activity}>
        <Chain live={live!} rates={rates} />
      </Section>

      {/* ── Tunnels + Lists side by side ─────────────────────── */}
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <Section title={`${t('Tunnels (failover)')} · ${onlineTun}/${rows.length} ${t('online')}`} icon={Network}>
          <Hint className="mb-2">{t('Failover hint')}.</Hint>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t('Tunnel')}</TableHead><TableHead>{t('Prio')}</TableHead><TableHead>{t('Handshake')}</TableHead>
                <TableHead>{t('Traffic')}</TableHead><TableHead>{t('Health')}</TableHead><TableHead>{t('Zone')}</TableHead>
                <TableHead title={t('Masquerade (masq) hides LAN behind the tunnel IP')}>{t('Masq')}</TableHead>
                <TableHead title={t('Forwarding lan → tunnel is required for traffic to reach the tunnel')}>{t('LAN fwd')}</TableHead>
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
                    <TableCell>{!e.fwKnown ? <span className="text-muted-foreground">…</span> : e.zone || <span className="text-destructive">{t('none')}</span>}</TableCell>
                    <TableCell>{!e.fwKnown ? <span className="text-muted-foreground">…</span> : <YesNo v={!!e.masq} />}</TableCell>
                    <TableCell>{!e.fwKnown ? <span className="text-muted-foreground">…</span> : <YesNo v={!!e.forwarding} />}</TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        </Section>

        <Section title={t('Lists')} icon={ListChecks}>
          {!haveDiag ? <Pending error={p.diagError} rows={3} onRetry={p.refresh} /> : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('List')}</TableHead><TableHead>{t('Entries')}</TableHead><TableHead>{t('Min')}</TableHead><TableHead>{t('Age')}</TableHead><TableHead>{t('State')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {lists.map((l) => (
                  <TableRow key={l.name}>
                    <TableCell>{l.name}</TableCell>
                    <TableCell>{l.enabled ? l.count : <span className="text-muted-foreground">({t('off')})</span>}</TableCell>
                    <TableCell>{l.min}</TableCell>
                    <TableCell>{fmtAge(l.age)}</TableCell>
                    <TableCell>{l.enabled ? <YesNo v={l.ok} /> : '—'}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </Section>
      </div>

      {/* ── Diagnostics + Events side by side ────────────────── */}
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <Section title={checks.length ? `${t('Diagnostics')} · ${checks.length}` : t('Diagnostics')} icon={Stethoscope}>
          {!haveDiag ? <Pending error={p.diagError} rows={2} onRetry={p.refresh} /> : checks.length === 0 ? (
            <p className="flex items-center gap-2 font-medium text-success">
              <CheckIcon className="size-4" />{t('No problems detected.')}
            </p>
          ) : (
            <div className="space-y-2">
              {checks.map((c) => (
                <div key={c.category + ':' + c.message} className={cn('flex flex-wrap items-center gap-2 rounded-md border-l-4 bg-muted/40 p-2.5', SEV[c.severity].ring)}>
                  <SevBadge sev={c.severity} />
                  <div className="min-w-[200px] flex-1">
                    <div>{c.message}</div>
                    {c.fix && <div className="mt-0.5 text-sm text-muted-foreground">→ {c.fix}</div>}
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
        </Section>

        <Section title={t('Event history')} icon={History}>
          {!haveDiag ? <Pending error={p.diagError} rows={2} onRetry={p.refresh} /> : events.length === 0 ? (
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
    </div>
  )
}

function MiniStat({ label, value, sub, tone }: { label: string; value: React.ReactNode; sub?: React.ReactNode; tone?: string }) {
  return (
    <div className="flex flex-col items-start">
      <div className="text-[11px] text-muted-foreground">{label}</div>
      <div className={cn('text-sm font-semibold leading-tight', tone)}>{value}</div>
      {sub != null && sub !== '' && <div className="text-[11px] text-muted-foreground">{sub}</div>}
    </div>
  )
}

function Section({ title, icon: Icon, children }: { title: string; icon: React.ComponentType<{ className?: string }>; children: React.ReactNode }) {
  return (
    <Card>
      {/* Argon section header: 1.1rem, normal weight, .875rem/1.25rem padding */}
      <CardHeader className="px-5 pb-2 pt-3.5">
        <CardTitle className="flex items-center gap-2 text-[1.1rem] font-normal">
          <Icon className="size-4 text-muted-foreground" />{title}
        </CardTitle>
      </CardHeader>
      <CardContent className="px-5 pb-4 pt-2">{children}</CardContent>
    </Card>
  )
}

// Маленькая подсказка под/рядом с термином — для рядового пользователя.
// Текст мелким «глухим» цветом, чтобы не отвлекать опытных, но объяснять
// суть (DPI, kill switch, masq и т.п.).
function Hint({ children, className }: { children: React.ReactNode; className?: string }) {
  return <p className={cn('text-xs text-muted-foreground', className)}>{children}</p>
}

// Путь трафика показан как три класса трафика, идущие параллельно прямо
// сейчас (а не «одна активная линия + резервы»). В каждой карточке — куда
// фактически уходит свой класс: заблокированные сайты (список ipsum),
// российский/нейтральный трафик (всегда напрямую, он в nozapret-исключении) и
// всё прочее (зависит от режима и наличия туннеля/zapret). Это честнее старой
// линейной цепочки, которая скрывала, что при активном VPN часть трафика
// параллельно идёт напрямую, а zapret реально работает, а не «спит в резерве».
type Tone = 'success' | 'warning' | 'destructive' | 'neutral'

const TONE: Record<Tone, { box: string; label: string }> = {
  success:    { box: 'bg-success/10 border-success/30 text-success',                    label: 'text-success' },
  warning:    { box: 'bg-warning/10 border-warning/30 text-warning',                    label: 'text-warning' },
  destructive:{ box: 'bg-destructive/10 border-destructive/30 text-destructive',        label: 'text-destructive' },
  neutral:    { box: 'bg-muted border-border text-muted-foreground',                    label: 'text-muted-foreground' },
}

function DestPill({ label, sub, tone }: { label: React.ReactNode; sub?: React.ReactNode; tone: Tone }) {
  const tn = TONE[tone]
  return (
    <div className={cn('flex flex-col items-center justify-center rounded-lg border px-4 py-2.5 text-center transition-colors', tn.box)}>
      <div className="text-sm font-semibold">{label}</div>
      {sub != null && sub !== '' && <div className="mt-1 text-[11px] opacity-80">{sub}</div>}
    </div>
  )
}

function PathCard({ title, dest, sub, tone }: {
  title: string; dest: React.ReactNode; sub?: React.ReactNode; tone: Tone
}) {
  return (
    <div className="flex flex-col justify-between gap-3 rounded-xl border bg-card p-4 shadow-sm">
      <div className="flex items-center justify-between text-xs font-medium text-muted-foreground">
        <span>{title}</span>
        <ArrowRight className="size-4 text-muted-foreground/50" />
      </div>
      <DestPill label={dest} sub={sub} tone={tone} />
    </div>
  )
}

function Chain({ live, rates }: { live: Live; rates: Record<string, Rate> }) {
  const s = live.summary
  const state = s.state || ''
  const mode = s.mode || ''
  const eps = live.endpoints || []

  const activeEp = eps.find((e) => state === 'vpn:' + e.iface)
  // zapret's presence now comes straight from the live read (the package is
  // detected and the daemon checked there), instead of being inferred from a
  // nozapret list row in the heavy snapshot.
  const zapretInstalled = !!s.zapret_version
  const zapretLabel = s.zapret_version || 'zapret'

  const isVpn = !!activeEp
  const isZapretState = state === 'zapret'
  const killed = state === 'killswitch'

  const rateOf = (iface: string) => rates[iface] || { rx: 0, tx: 0 }
  const vpnSub = activeEp ? (
    <span className="whitespace-nowrap">
      <span className="text-success">↓{fmtRate(rateOf(activeEp.iface).rx)}</span>{' '}
      <span className="text-info">↑{fmtRate(rateOf(activeEp.iface).tx)}</span>
    </span>
  ) : undefined

  // ── Карточка ① «Заблокированные сайты» (список ipsum) ──
  // При живом VPN — через туннель; при падении VPN — zapret; без zapret — открытый WAN.
  let card1: { dest: React.ReactNode; sub?: React.ReactNode; tone: Tone }
  if (killed) {
    card1 = { dest: t('Blocked — kill switch'), tone: 'destructive' }
  } else if (isVpn) {
    card1 = { dest: `#${activeEp!.priority || '?'} ${activeEp!.iface}`, sub: vpnSub, tone: 'success' }
  } else if (isZapretState || zapretInstalled) {
    card1 = { dest: zapretLabel, sub: t('DPI bypass (zapret)'), tone: 'success' }
  } else {
    card1 = { dest: t('Open (WAN)'), sub: t('Direct (WAN)'), tone: 'neutral' }
  }

  // ── Карточка ② «Российский / нейтральный трафик» ──
  // RU/приватные сети всегда в nozapret (или direct-исключении в full) → всегда
  // идут напрямую через WAN. kill switch глушит и их.
  const card2: { dest: React.ReactNode; sub?: React.ReactNode; tone: Tone } = killed
    ? { dest: t('Blocked — kill switch'), tone: 'destructive' }
    : { dest: t('Direct (WAN)'), sub: t('via WAN'), tone: 'success' }

  // ── Карточка ③ «Прочий трафик» ──
  // full + VPN → через туннель. Иначе трафик выходит через WAN, но, в отличие
  // от RU/нейтрального (карточка ②, который лежит в nozapret), «прочий» НЕ в
  // nozapret — поэтому zapret обрабатывает его (DPI-обход). Без zapret —
  // действительно напрямую.
  let card3: { dest: React.ReactNode; sub?: React.ReactNode; tone: Tone }
  if (killed) {
    card3 = { dest: t('Blocked — kill switch'), tone: 'destructive' }
  } else if (mode === 'full' && isVpn) {
    card3 = { dest: `#${activeEp!.priority || '?'} ${activeEp!.iface}`, sub: t('via VPN'), tone: 'success' }
  } else if (zapretInstalled || isZapretState) {
    card3 = { dest: zapretLabel, sub: t('DPI bypass (zapret)'), tone: 'success' }
  } else {
    card3 = { dest: t('Direct (WAN)'), sub: t('via WAN'), tone: 'neutral' }
  }

  const cards = [
    { title: t('Blocked sites'),   ...card1 },
    { title: t('RU / neutral'),    ...card2 },
    { title: t('Other traffic'),   ...card3 },
  ]

  return (
    <div className="space-y-2">
      <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
        {cards.map((c) => (
          <PathCard key={c.title} title={c.title} dest={c.dest} sub={c.sub} tone={c.tone} />
        ))}
      </div>
      <p className="text-center text-xs text-muted-foreground">
        LAN:{' '}{s.lan_iface || '—'}{' → '}{t('Internet')}
      </p>
    </div>
  )
}
