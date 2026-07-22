import { useRef } from 'react'
import type { Status, EventRow, Check, Sev } from '@/lib/rpc'
import { rpc } from '@/lib/rpc'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
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
  fmtAge, fmtRate, fmtWhen, pathLabel, EVENT_META, ratesFor, type RateSample,
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
  if (health === 'ok' || health === 'OK') return <span className="flex items-center gap-1 text-success"><CheckIcon className="size-4" />ок</span>
  if (health === 'idle') return <span className="flex items-center gap-1 text-muted-foreground"><Minus className="size-4" />простой</span>
  if (health === 'FAIL') return <span className="flex items-center gap-1 text-destructive"><XIcon className="size-4" />FAIL</span>
  return <span className="text-muted-foreground">—</span>
}

interface Props {
  status: Status | null
  events: EventRow[]
  wgIfaces: string[]
  busy: string
  setBusy: (s: string) => void
  refresh: () => void
}

export default function StatusDashboard(p: Props) {
  const { status, events } = p
  const ratesRef = useRef<RateSample>({})

  if (!status || !status.summary) {
    return (
      <Card>
        <CardContent className="p-8 text-center text-destructive">
          Диагностика недоступна — служба splify установлена и запущена?
        </CardContent>
      </Card>
    )
  }

  const s = status.summary
  const now = Date.now()
  const eps = status.endpoints || []
  const rates: Record<string, { rx: number; tx: number }> = {}
  eps.forEach((e) => { rates[e.iface] = ratesFor(e, now, ratesRef.current) })

  const overall = status.overall || 'FAIL'
  const path = pathLabel(s.state || '')
  const HeroIcon = stateIcon(s.state || '')
  const isOn = /^vpn:/.test(s.state) || s.state === 'zapret' || s.state === 'killswitch'

  // ── KPI aggregates for the stat blocks ──────────────────────
  const activeEp = eps.find((e) => s.state === 'vpn:' + e.iface)
  const totRx = eps.reduce((a, e) => a + (rates[e.iface]?.rx || 0), 0)
  const totTx = eps.reduce((a, e) => a + (rates[e.iface]?.tx || 0), 0)
  const onlineTun = eps.filter((e) => e.present).length
  const lists = status.lists || []
  const enabledLists = lists.filter((l) => l.enabled)
  const okLists = enabledLists.filter((l) => l.ok).length

  async function run(action: string, confirmMsg?: string, toast?: string) {
    if (confirmMsg && !window.confirm(confirmMsg)) return
    p.setBusy(action)
    try {
      const res = await rpc.action(action)
      notify((toast || action) + (res?.code !== 0 && res?.stdout ? ': ' + res.stdout : ''), res?.code === 0 ? 'info' : 'warning')
      p.refresh()
    } catch (e: any) {
      notify(action + ': ' + (e?.message || e), 'error')
    } finally {
      p.setBusy('')
    }
  }

  async function fixFirewall(c: Check) {
    const m = /^([A-Za-z0-9_.-]+):/.exec(c.message || '')
    if (!m) return
    const iface = m[1]
    if (!window.confirm(t('Create/repair the firewall zone for “%s” (accept-all + masquerading + lan↔tunnel↔wan forwarding) and reload the firewall?').replace('%s', iface))) return
    p.setBusy('fw_fix')
    try {
      const res = await rpc.action('fw_fix', iface)
      const okMsg = t('Firewall fixed for %s').replace('%s', iface)
      const errMsg = t('Could not fix firewall for %s').replace('%s', iface)
      notify((res?.code === 0 ? okMsg : errMsg) + (res?.stdout ? ': ' + res.stdout : ''), res?.code === 0 ? 'info' : 'warning')
      p.refresh()
    } catch (e: any) {
      notify(t('Firewall fix error:') + ' ' + (e?.message || e), 'error')
    } finally {
      p.setBusy('')
    }
  }

  // A toolbar action button that shows a spinner while its action is running.
  function ActBtn({ a, label, icon: Icon, variant = 'outline', confirm, toast, className }: {
    a: string; label: string; icon: React.ComponentType<{ className?: string }>
    variant?: 'default' | 'outline' | 'secondary' | 'destructive' | 'ghost'
    confirm?: string; toast?: string; className?: string
  }) {
    return (
      <Button size="sm" variant={variant} className={className} disabled={!!p.busy}
        onClick={() => run(a, confirm, toast)}>
        {p.busy === a ? <RefreshCw className="size-4 animate-spin" /> : <Icon className="size-4" />}
        {label}
      </Button>
    )
  }

  const checks = (status.checks || []).filter((c) => c.severity !== 'OK')
  const firstRun = eps.length === 0

  return (
    <div className="space-y-4">
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
                {t('Mode')} <b className="text-foreground">{s.mode || '?'}</b> · {t('Kill switch')} <b className="text-foreground">{String(s.killswitch) === '1' ? t('on') : t('off')}</b>
                {s.zapret_version && <> · DPI: <b className="text-foreground">{s.zapret_version}</b></>}
              </div>
              <Hint className="mt-1">
                {String(s.killswitch) === '1' ? t('Kill switch hint') : t('DPI bypass hint')}
              </Hint>
            </div>
          </div>

          <div className="flex flex-wrap items-center gap-x-5 gap-y-1">
            <MiniStat label={t('Tunnel')} value={activeEp ? activeEp.iface : '—'}
              sub={activeEp ? t('handshake') + ' ' + fmtAge(activeEp.handshake_age) : undefined} />
            <MiniStat label={t('RX')} value={fmtRate(totRx)} />
            <MiniStat label={t('TX')} value={fmtRate(totTx)} />
            <MiniStat label={t('Failures')} value={String(s.fail_count ?? '?')} tone={(s.fail_count ?? 0) > 0 ? SEV.WARN.text : undefined} />
            <MiniStat label={t('Lists OK')} value={`${okLists}/${enabledLists.length}`} tone={okLists < enabledLists.length ? SEV.WARN.text : undefined} />
          </div>

          <div className="flex items-center gap-2">
            <SevBadge sev={overall} />
            <Button size="sm" disabled={!!p.busy}
              variant={isOn ? 'outline' : 'default'}
              className={isOn
                ? 'border-destructive text-destructive hover:bg-destructive/10'
                : 'bg-success text-white hover:bg-success/90'}
              onClick={() => run(isOn ? 'off' : 'on',
                isOn ? t('Turn off split routing? All LAN traffic will go via WAN until the service re-enables it.') : undefined,
                isOn ? t('Split routing disabled') : t('Split routing enabled'))}>
              <Power className="size-4" />{isOn ? t('Disable') : t('Enable')}
            </Button>
          </div>
        </CardContent>
      </Card>

      {/* ── Toolbar (carded, so it reads as one control block) ── */}
      <Card>
        <CardContent className="flex flex-wrap items-center gap-2 p-3">
          <Button size="sm" variant="outline" disabled={!!p.busy} onClick={p.refresh}>
            <RefreshCw className="size-4" />{t('Refresh')}
          </Button>
          <ActBtn a="apply" label={t('Apply')} icon={Play} variant="default" toast={t('Configuration applied')} />
          <ActBtn a="restart" label={t('Restart')} icon={RotateCw} variant="secondary" toast={t('Service restarted')} />

          <div className="flex items-center gap-1 rounded-lg border bg-muted/40 px-1 py-1">
            <span className="px-1.5 text-xs text-muted-foreground">{t('Lists')}</span>
            <ActBtn a="update_ipsum" label="ipsum" icon={Download} variant="ghost" toast={t('ipsum updated')} />
            <ActBtn a="update_ru" label="ru/cn" icon={Download} variant="ghost" toast={t('ru/cn updated')} />
            <ActBtn a="update_domains" label="домены" icon={Download} variant="ghost" toast={t('domains updated')} />
          </div>

          <div className="flex-1" />

          <ActBtn a="disable" label={t('Emergency disable')} icon={Power} variant="destructive"
            confirm={t('Disable split routing now? All LAN traffic will exit via WAN until the service re-enables it (or you stop it).')}
            toast={t('Split routing disabled')} />
        </CardContent>
      </Card>

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
        <Chain status={status} rates={rates} />
      </Section>

      {/* ── Tunnels + Lists side by side ─────────────────────── */}
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <Section title={`${t('Tunnels (failover)')} · ${onlineTun}/${eps.length} ${t('online')}`} icon={Network}>
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
              {eps.map((e) => {
                const r = rates[e.iface] || { rx: 0, tx: 0 }
                return (
                  <TableRow key={e.iface}>
                    <TableCell className="font-medium">{e.present ? e.iface : <span className="text-destructive">{e.iface} (нет)</span>}</TableCell>
                    <TableCell>{e.priority || '—'}</TableCell>
                    <TableCell>{e.present ? fmtAge(e.handshake_age) : '—'}</TableCell>
                    <TableCell className="whitespace-nowrap">{e.present ? <><span className="text-success">↓{fmtRate(r.rx)}</span> <span className="text-info">↑{fmtRate(r.tx)}</span></> : '—'}</TableCell>
                    <TableCell><HealthState health={e.health} /></TableCell>
                    <TableCell>{e.zone || <span className="text-destructive">нет</span>}</TableCell>
                    <TableCell><YesNo v={e.masq} /></TableCell>
                    <TableCell><YesNo v={e.forwarding} /></TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        </Section>

        <Section title="Списки" icon={ListChecks}>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Список</TableHead><TableHead>Записей</TableHead><TableHead>Мин</TableHead><TableHead>Возраст</TableHead><TableHead>Состояние</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {lists.map((l) => (
                <TableRow key={l.name}>
                  <TableCell>{l.name}</TableCell>
                  <TableCell>{l.enabled ? l.count : <span className="text-muted-foreground">(выкл)</span>}</TableCell>
                  <TableCell>{l.min}</TableCell>
                  <TableCell>{fmtAge(l.age)}</TableCell>
                  <TableCell>{l.enabled ? <YesNo v={l.ok} /> : '—'}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Section>
      </div>

      {/* ── Diagnostics + Events side by side ────────────────── */}
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <Section title={checks.length ? `${t('Diagnostics')} · ${checks.length}` : t('Diagnostics')} icon={Stethoscope}>
          {checks.length === 0 ? (
            <p className="flex items-center gap-2 font-medium text-success">
              <CheckIcon className="size-4" />{t('No problems detected.')}
            </p>
          ) : (
            <div className="space-y-2">
              {checks.map((c, i) => (
                <div key={i} className={cn('flex flex-wrap items-center gap-2 rounded-md border-l-4 bg-muted/40 p-2.5', SEV[c.severity].ring)}>
                  <SevBadge sev={c.severity} />
                  <div className="min-w-[200px] flex-1">
                    <div>{c.message}</div>
                    {c.fix && <div className="mt-0.5 text-sm text-muted-foreground">→ {c.fix}</div>}
                  </div>
                  {c.category === 'firewall' && !/in the shared |device wildcard|non-tunnel networks/.test(c.message) && /^([A-Za-z0-9_.-]+):/.test(c.message) && (
                    <Button size="sm" variant="outline" className="border-primary text-primary" disabled={!!p.busy} onClick={() => fixFirewall(c)}>
                      <Wrench className="size-4" />{t('Fix')}
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
          {events.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('No failover events recorded yet.')}</p>
          ) : (
            <Table>
              <TableBody>
                {events.slice(0, 50).map((ev, i) => {
                  const m = EVENT_META[ev.kind] || { i: '•', cls: 'text-muted-foreground', ru: ev.kind }
                  const pathStr = ev.from && ev.to ? `${ev.from} → ${ev.to}` : ev.to || ev.from || ''
                  return (
                    <TableRow key={i}>
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

function Chain({ status, rates }: { status: Status; rates: Record<string, { rx: number; tx: number }> }) {
  const s = status.summary
  const state = s.state || ''
  const eps = status.endpoints || []

  // Узел пути. `active` — подсвечивает реально идущую через него ветку
  // (success ring); `dead` — недоступный туннель (деструктивный цвет); прочие
  // «спят» (нейтральный фон). Активным бывает ровно один узел цепочки.
  const Node = ({ title, sub, active, dead }: { title: string; sub?: React.ReactNode; active?: boolean; dead?: boolean }) => (
    <div className={cn(
      'flex min-w-[88px] flex-col justify-center rounded-lg border px-3 py-2 text-center',
      active && 'border-success bg-success/10 ring-2 ring-success/30',
      dead && 'border-destructive text-destructive',
      !active && !dead && 'bg-muted/40',
    )}>
      <div className="text-sm font-semibold">{title}</div>
      {sub != null && sub !== '' && <div className="mt-0.5 text-xs text-muted-foreground">{sub}</div>}
    </div>
  )
  // Яркая стрелка для активной ветки, бледная — для сна/резерва.
  const Arrow = ({ dim }: { dim?: boolean }) => (
    <ArrowRight className={cn('size-4 self-center', dim ? 'text-muted-foreground/30' : 'text-muted-foreground/70')} />
  )

  const activeEp = eps.find((e) => state === 'vpn:' + e.iface)
  const hasZapret = (status.lists || []).some((l) => l.name === 'nozapret') || state === 'zapret'

  // Резервы = все туннели КРОМЕ активного (по приоритету), плюс zapret и WAN
  // как нижние ступени. На экран выводятся компактным списком бейджей, без
  // стрелок — чтобы не путать с реально активной цепочкой выше.
  const reserves = eps
    .filter((e) => e !== activeEp)
    .sort((a, b) => (Number(a.priority) || 999) - (Number(b.priority) || 999))

  const rateOf = (iface: string) => rates[iface] || { rx: 0, tx: 0 }
  const liveSub = (e: typeof eps[number]) => {
    if (!e.present) return t('none')
    const r = rateOf(e.iface)
    return <span className="whitespace-nowrap"><span className="text-success">↓{fmtRate(r.rx)}</span> <span className="text-info">↑{fmtRate(r.tx)}</span></span>
  }

  // ── активная цепочка (ровно один реальный маршрут LAN → … → Интернет) ──
  let chain: React.ReactNode
  if (state === 'killswitch') {
    chain = <>
      <Node title="LAN" sub={s.lan_iface} />
      <Arrow />
      <div className="flex min-w-[88px] flex-col justify-center rounded-lg border border-destructive bg-destructive/10 px-3 py-2 text-center ring-2 ring-destructive/30">
        <div className="text-sm font-semibold">{t('Blocked — kill switch')}</div>
      </div>
      <Arrow />
      <Node title={t('Internet')} sub={t('none')} dead />
    </>
  } else if (activeEp) {
    chain = <>
      <Node title="LAN" sub={s.lan_iface} />
      <Arrow />
      <Node title={`#${activeEp.priority || '?'} ${activeEp.iface}`} sub={liveSub(activeEp)} active />
      <Arrow />
      <Node title={t('Internet')} sub={t('via VPN')} active />
    </>
  } else if (state === 'zapret') {
    chain = <>
      <Node title="LAN" sub={s.lan_iface} />
      <Arrow />
      <Node title={s.zapret_version || 'zapret'} sub={t('DPI bypass (zapret)')} active />
      <Arrow />
      <Node title={t('Internet')} sub={t('Direct (WAN)')} active />
    </>
  } else {
    // wan или неизвестное — рисуем как «напрямую», без активного туннеля.
    chain = <>
      <Node title="LAN" sub={s.lan_iface} />
      <Arrow />
      <Node title={t('Internet')} sub={t('Direct (WAN)')} active />
    </>
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-stretch gap-1.5">{chain}</div>

      {/* Резервы — отдельной строкой, чтобы не сливаться с активным путём.
          Показываем, что ВООБЩЕ настроено и в каком порядке встанет, если
          активная ветка упадёт. Текст «глухой» подсказки объясняет, что это. */}
      {reserves.length > 0 || hasZapret ? (
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="text-xs text-muted-foreground">{t('Reserves by priority')}:</span>
          {reserves.map((e) => (
            <span key={e.iface} className={cn(
              'inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-xs',
              e.present ? 'border-border bg-muted/40' : 'border-destructive/50 text-destructive',
            )}>
              #{e.priority || '?'} {e.iface}{!e.present && ` (${t('none')})`}
            </span>
          ))}
          {hasZapret && state !== 'zapret' && (
            <span className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/40 px-2 py-0.5 text-xs">
              {s.zapret_version || 'zapret'}
            </span>
          )}
          {state !== 'wan' && state !== 'killswitch' && (
            <span className="inline-flex items-center gap-1 rounded-md border border-border bg-muted/40 px-2 py-0.5 text-xs">WAN</span>
          )}
        </div>
      ) : (
        <p className="text-xs text-muted-foreground">{t('No reserves — all configured tunnels are down.')}</p>
      )}
    </div>
  )
}
