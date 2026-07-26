import { useEffect, useRef, useState } from 'react'
import { uci, arr, wgIfaces, ipHints, type Section } from '@/lib/uci'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { notify } from '@/lib/notify'
import { t } from '@/lib/i18n'
import {
  Settings2, ListChecks, Network, ShieldCheck, Globe, Activity, Save, Check as CheckIcon,
  Plus, X as XIcon, Router, MonitorSmartphone, Loader2,
} from 'lucide-react'

const field = 'w-full rounded-md border border-input bg-background px-2.5 py-1.5 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring'
const lbl = 'mb-1 block text-xs text-muted-foreground'
const hint = 'mt-1 text-xs text-muted-foreground'

type Tab = 'general' | 'lists' | 'manual' | 'endpoints' | 'devices'
const NAV: { id: Tab; label: string; icon: React.ComponentType<{ className?: string }> }[] = [
  { id: 'general', label: 'Основное', icon: Settings2 },
  { id: 'lists', label: 'Списки', icon: ListChecks },
  { id: 'manual', label: 'Ручные записи', icon: Network },
  { id: 'endpoints', label: 'Туннели', icon: Router },
  { id: 'devices', label: 'Устройства', icon: MonitorSmartphone },
]

interface GeneralForm {
  mode: string; interval: string; killswitch: boolean
  lan_iface: string; lan_cidr: string; health_url: string
  health_target: string[]
}
interface ListsForm {
  ipsum_enabled: boolean; ipsum_url: string
  ru_enabled: boolean; ru_url: string
  vpn_domains_url: string; ignore_domains_url: string
  zapret_enabled: boolean
}
interface ManualForm {
  vpn_cidr: string[]; direct_cidr: string[]; vpn_domain: string[]; direct_domain: string[]
}
interface EndpointRow { sid: string; iface: string; priority: string; type: string; isNew?: boolean }
interface DeviceRow { sid: string; ip: string; mode: string; isNew?: boolean }

const newId = () => '_new_' + Math.random().toString(36).slice(2)

function Switch({ on, onClick, disabled, 'aria-label': ariaLabel }: { on: boolean; onClick: () => void; disabled?: boolean; 'aria-label'?: string }) {
  return (
    <button type="button" onClick={onClick} disabled={disabled}
      role="switch" aria-checked={on} aria-label={ariaLabel}
      className={cn('relative h-6 w-11 shrink-0 rounded-full transition disabled:opacity-50', on ? 'bg-success' : 'bg-muted-foreground/30')}>
      <span className={cn('absolute left-0.5 top-0.5 size-5 rounded-full bg-white transition-transform', on && 'translate-x-5')} />
    </button>
  )
}

function Section({ title, icon: Icon, desc, children, right }: {
  title: string; icon: React.ComponentType<{ className?: string }>; desc?: string
  children: React.ReactNode; right?: React.ReactNode
}) {
  return (
    <Card>
      <CardHeader className="flex-row items-start justify-between gap-3 space-y-0 p-4 pb-2">
        <div>
          <CardTitle className="flex items-center gap-2 text-[1.1rem] font-normal"><Icon className="size-4 text-muted-foreground" />{title}</CardTitle>
          {desc && <p className="mt-1 text-xs text-muted-foreground">{desc}</p>}
        </div>
        {right}
      </CardHeader>
      <CardContent className="space-y-3 p-4 pt-2">{children}</CardContent>
    </Card>
  )
}

function Field({ label, children, helpText }: { label: string; children: React.ReactNode; helpText?: string }) {
  return (
    <div>
      <span className={lbl}>{label}</span>
      {children}
      {helpText && <p className={hint}>{helpText}</p>}
    </div>
  )
}

// Reusable add/remove text-row editor — ports the DynamicList UX from the old
// settings.js form (green "+" to add, red "×" to remove) used for ping
// targets, manual CIDRs and manual domains.
function ListEditor({ values, onChange, placeholder }: { values: string[]; onChange: (v: string[]) => void; placeholder?: string }) {
  const rows = [...values, '']
  function update(i: number, v: string) {
    const next = [...values]
    next[i] = v
    onChange(next)
  }
  function add(v: string) {
    if (!v.trim()) return
    onChange([...values, v.trim()])
  }
  function remove(i: number) {
    onChange(values.filter((_, idx) => idx !== i))
  }
  return (
    <div className="space-y-2">
      {rows.map((v, i) => {
        const isLast = i === rows.length - 1
        return (
          <div key={i} className="flex gap-2">
            <input className={field} value={v} placeholder={placeholder}
              onChange={(e) => update(i, e.target.value)}
              onKeyDown={(e) => {
                // Enter commits the trailing draft row. add() appends to the
                // values array; the new tail `''` (from `rows = [...values, ''`)
                // then renders as a fresh empty input on the next commit. We
                // intentionally do NOT also commit on blur: blurring leaves the
                // typed text in the controlled input AND appends it, producing a
                // visible duplicate; Enter is an explicit, unambiguous commit.
                if (e.key === 'Enter' && isLast && (e.target as HTMLInputElement).value.trim()) {
                  add((e.target as HTMLInputElement).value)
                }
              }} />
            {isLast
              ? <Button type="button" size="icon" variant="secondary" className="bg-success text-white hover:bg-success/90"
                  aria-label={t('Add')} title={t('Add')}
                  onClick={(e) => {
                    const input = e.currentTarget.previousSibling as HTMLInputElement | null
                    if (input?.value.trim()) { add(input.value) }
                  }}>
                  <Plus className="size-4" />
                </Button>
              : <Button type="button" size="icon" variant="destructive" onClick={() => remove(i)} aria-label={t('Delete')} title={t('Delete')}>
                  <XIcon className="size-4" />
                </Button>}
          </div>
        )
      })}
    </div>
  )
}

export default function SettingsPage() {
  const [tab, setTab] = useState<Tab>('general')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState('')
  const [dirty, setDirty] = useState(false)

  const [hasLoaded, setHasLoaded] = useState(false)
  const [ifaces, setIfaces] = useState<string[]>([])
  const [hostHints, setHostHints] = useState<[string, string][]>([])

  const [general, setGeneral] = useState<GeneralForm>({
    mode: 'blocklist', interval: '', killswitch: false, lan_iface: '', lan_cidr: '', health_url: '', health_target: [],
  })
  const [lists, setLists] = useState<ListsForm>({
    ipsum_enabled: true, ipsum_url: '', ru_enabled: true, ru_url: '', vpn_domains_url: '', ignore_domains_url: '', zapret_enabled: true,
  })
  const [manual, setManual] = useState<ManualForm>({ vpn_cidr: [], direct_cidr: [], vpn_domain: [], direct_domain: [] })
  const [endpoints, setEndpoints] = useState<EndpointRow[]>([])
  const [devices, setDevices] = useState<DeviceRow[]>([])
  // Sids present at the last load() — the basis for detecting rows the user
  // has since removed (filter button). Those must be uci.remove()'d in commit(),
  // otherwise the deleted section reappears on the next reload.
  const loadedEndpointSids = useRef<Set<string>>(new Set())
  const loadedDeviceSids = useRef<Set<string>>(new Set())

  function mark<T>(setter: (v: T) => void) {
    return (v: T) => { setDirty(true); setter(v) }
  }

  async function load() {
    setLoading(true)
    try {
      await uci.load()
      const g = (sid: string, def = '') => { const v = uci.get('global', sid); return v == null ? def : String(v) }
      setGeneral({
        mode: g('mode', 'blocklist'), interval: g('interval'), killswitch: g('killswitch') === '1',
        lan_iface: g('lan_iface'), lan_cidr: g('lan_cidr'), health_url: g('health_url'),
        health_target: arr(uci.get('global', 'health_target')),
      })
      setLists({
        ipsum_enabled: g('ipsum_enabled', '1') === '1', ipsum_url: g('ipsum_url'),
        ru_enabled: g('ru_enabled', '1') === '1', ru_url: g('ru_url'),
        vpn_domains_url: g('vpn_domains_url'), ignore_domains_url: g('ignore_domains_url'),
        zapret_enabled: g('zapret_enabled', '1') === '1',
      })
      setManual({
        vpn_cidr: arr(uci.get('global', 'vpn_cidr')), direct_cidr: arr(uci.get('global', 'direct_cidr')),
        vpn_domain: arr(uci.get('global', 'vpn_domain')), direct_domain: arr(uci.get('global', 'direct_domain')),
      })
      const epSections = uci.sections('endpoint')
      const devSections = uci.sections('device')
      setEndpoints(epSections.map((s: Section) => ({
        sid: s['.name'], iface: s.iface || '', priority: s.priority || '', type: s.type || 'wg',
      })).sort((a, b) => (parseInt(a.priority) || 0) - (parseInt(b.priority) || 0)))
      setDevices(devSections.map((s: Section) => ({ sid: s['.name'], ip: s.ip || '', mode: s.mode || 'vpn' })))
      loadedEndpointSids.current = new Set(epSections.map((s) => s['.name']))
      loadedDeviceSids.current = new Set(devSections.map((s) => s['.name']))
      const [ifs, hh] = await Promise.all([
        wgIfaces(),
        Promise.resolve(window.__splifyHostHints || {}),
      ])
      setIfaces(ifs)
      setHostHints(ipHints(hh))
      setError('')
      setDirty(false)
      setHasLoaded(true)
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => { load() }, []) // eslint-disable-line react-hooks/exhaustive-deps

  function commit() {
    const g = (k: string, v: string | string[] | boolean) => {
      const val = typeof v === 'boolean' ? (v ? '1' : '0') : v
      if (Array.isArray(val)) {
        const filtered = val.filter(s => s.trim() !== '')
        uci.set('global', k, filtered.length > 0 ? filtered : undefined)
      } else {
        uci.set('global', k, val)
      }
    }
    g('mode', general.mode); g('interval', general.interval); g('killswitch', general.killswitch)
    g('lan_iface', general.lan_iface); g('lan_cidr', general.lan_cidr); g('health_url', general.health_url)
    g('health_target', general.health_target)
    g('ipsum_enabled', lists.ipsum_enabled); g('ipsum_url', lists.ipsum_url)
    g('ru_enabled', lists.ru_enabled); g('ru_url', lists.ru_url)
    g('vpn_domains_url', lists.vpn_domains_url); g('ignore_domains_url', lists.ignore_domains_url)
    g('zapret_enabled', lists.zapret_enabled)
    g('vpn_cidr', manual.vpn_cidr); g('direct_cidr', manual.direct_cidr)
    g('vpn_domain', manual.vpn_domain); g('direct_domain', manual.direct_domain)

    // Diff against the last load(): any sid that was present then but is gone
    // from the current array was removed by the user — delete the section, or
    // it silently reappears on the next reload (this was the "туннели не
    // сохраняются" bug — new/edits were written but deletions were dropped).
    const keepEndpoint = new Set(endpoints.filter((e) => !e.isNew).map((e) => e.sid))
    for (const sid of loadedEndpointSids.current) {
      if (!keepEndpoint.has(sid)) uci.remove(sid)
    }
    const keepDevice = new Set(devices.filter((d) => !d.isNew).map((d) => d.sid))
    for (const sid of loadedDeviceSids.current) {
      if (!keepDevice.has(sid)) uci.remove(sid)
    }

    for (const e of endpoints) {
      const sid = e.isNew ? uci.add('endpoint') : e.sid
      uci.set(sid, 'iface', e.iface); uci.set(sid, 'priority', e.priority); uci.set(sid, 'type', e.type || 'wg')
    }
    for (const d of devices) {
      const sid = d.isNew ? uci.add('device') : d.sid
      uci.set(sid, 'ip', d.ip.trim()); uci.set(sid, 'mode', d.mode)
    }
  }

  async function save(apply: boolean) {
    setBusy(apply ? 'apply' : 'save')
    try {
      commit()
      await uci.save()
      if (apply) {
        // apply() commits to /etc/config + reloads services + starts the
        // rollback timer (it persists as a side effect of ubus uci.apply).
        await uci.apply()
      } else {
        // save() only stages to /tmp/.uci — commit explicitly so the edit
        // survives a reboot without forcing a service reload right now.
        await uci.commit()
      }
      notify(apply ? 'Настройки сохранены и применены' : 'Настройки сохранены', 'info')
      await load()
    } catch (e: any) {
      notify('Ошибка сохранения: ' + (e?.message || e), 'error')
    } finally {
      setBusy('')
    }
  }

  if (loading && !hasLoaded) return <div className="p-8 text-center text-muted-foreground animate-pulse">Загрузка настроек…</div>
  if (error && !hasLoaded) return <Card><CardContent className="p-8 text-center text-destructive">Ошибка: {error}</CardContent></Card>

  return (
    <div className="space-y-4">
      {/* A reload error after a successful save shouldn't blank an otherwise-working
          settings page — keep the last-good form visible and surface this instead. */}
      {error && hasLoaded && (
        <Card className="border-destructive/50"><CardContent className="flex items-center justify-between gap-3 p-3 text-sm text-destructive">
          <span>Не удалось обновить данные: {error}</span>
          <Button size="sm" variant="outline" onClick={() => load()}>Повторить</Button>
        </CardContent></Card>
      )}
      <Card>
        <CardContent className="flex flex-wrap items-start justify-between gap-3 p-5">
          <div>
            <h1 className="text-base font-semibold tracking-tight">Дополнительные настройки</h1>
            <p className="mt-1 max-w-2xl text-sm text-muted-foreground">
              Тонкая настройка splify: режим маршрутизации, туннели с приоритетом, списки, обход DPI (zapret),
              ручные подсети/домены и правила для устройств. Туннели создаются обычным образом в Сеть → Интерфейсы,
              затем добавляются по приоритету в разделе «Туннели». Простое управление и состояние — на вкладке «Главная».
            </p>
          </div>
          <div className="flex items-center gap-2">
            {dirty && <Badge variant="outline" className="border-warning text-warning">не сохранено</Badge>}
            <Button size="sm" variant="outline" disabled={!!busy} onClick={() => save(false)}>
              {busy === 'save' ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}Сохранить
            </Button>
            <Button size="sm" disabled={!!busy} onClick={() => save(true)}>
              {busy === 'apply' ? <Loader2 className="size-4 animate-spin" /> : <CheckIcon className="size-4" />}Сохранить и применить
            </Button>
          </div>
        </CardContent>
      </Card>

      <div className="flex flex-col gap-4 md:flex-row">
        {/* ── Left sub-nav ─────────────────────────────────────── */}
        <nav className="flex shrink-0 flex-row gap-1 overflow-x-auto md:w-44 md:flex-col md:overflow-visible">
          {NAV.map(({ id, label, icon: Icon }) => {
            const active = tab === id
            const count = id === 'endpoints' ? endpoints.length : id === 'devices' ? devices.length : null
            return (
              <button key={id} onClick={() => setTab(id)}
                className={cn('flex items-center gap-2 whitespace-nowrap rounded-lg px-3 py-2 text-left text-sm transition',
                  // Argon sidebar: active item = primary fill + white text
                  active ? 'bg-primary font-medium text-primary-foreground' : 'text-muted-foreground hover:bg-primary/90 hover:text-primary-foreground')}>
                <Icon className="size-4 shrink-0" />{label}
                {count != null && <span className={cn('ml-auto text-xs', active ? 'text-primary-foreground/80' : 'text-muted-foreground')}>{count}</span>}
              </button>
            )
          })}
        </nav>

        {/* ── Right content ────────────────────────────────────── */}
        <div className="min-w-0 flex-1 space-y-4">
          {tab === 'general' && (
            <>
              <Section title="Режим маршрутизации" icon={ShieldCheck}>
                <Field label="Режим">
                  <select className={field} value={general.mode} onChange={(e) => mark(setGeneral)({ ...general, mode: e.target.value })}>
                    <option value="blocklist">Через VPN только заблокированное (рекомендуется)</option>
                    <option value="full">Всё через VPN, исключения — напрямую</option>
                    <option value="split">Через VPN только выбранные списки/домены</option>
                  </select>
                </Field>
                <div className="flex items-center justify-between rounded-md border bg-muted/30 p-3">
                  <div>
                    <div className="text-sm font-medium">Блокировать трафик, если туннель недоступен</div>
                    <div className="text-xs text-muted-foreground">Когда все туннели недоступны — блокировать VPN-трафик, а не выпускать его в WAN.</div>
                  </div>
                  <Switch on={general.killswitch} onClick={() => mark(setGeneral)({ ...general, killswitch: !general.killswitch })} aria-label={t('Блокировать трафик, если туннель недоступен')} />
                </div>
              </Section>

              <Section title="Проверка связности" icon={Activity}>
                <Field label="Интервал проверки (сек)" helpText="Секунды между проверками туннелей и переключением при сбое.">
                  <input className={cn(field, 'w-32')} value={general.interval} placeholder="180"
                    onChange={(e) => mark(setGeneral)({ ...general, interval: e.target.value })} />
                </Field>
                <Field label="Адреса для проверки туннеля (ping)" helpText="Пингуются через каждый туннель для проверки (любой ответ = туннель жив).">
                  <ListEditor values={general.health_target} placeholder="1.1.1.1" onChange={(v) => mark(setGeneral)({ ...general, health_target: v })} />
                </Field>
                <Field label="URL проверки WAN" helpText="Запрашивается через WAN, чтобы выбрать между обходом DPI и прямым WAN.">
                  <input className={field} value={general.health_url} placeholder="https://1.1.1.1/cdn-cgi/trace"
                    onChange={(e) => mark(setGeneral)({ ...general, health_url: e.target.value })} />
                </Field>
              </Section>

              <Section title="LAN" icon={Globe}>
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  <Field label="LAN-интерфейс">
                    <input className={field} value={general.lan_iface} placeholder="br-lan"
                      onChange={(e) => mark(setGeneral)({ ...general, lan_iface: e.target.value })} />
                  </Field>
                  <Field label="Подсеть LAN (CIDR)">
                    <input className={field} value={general.lan_cidr} placeholder="192.168.1.0/24"
                      onChange={(e) => mark(setGeneral)({ ...general, lan_cidr: e.target.value })} />
                  </Field>
                </div>
              </Section>
            </>
          )}

          {tab === 'lists' && (
            <>
              <Section title="ipsum — список IP для VPN" icon={ListChecks}
                right={<Switch on={lists.ipsum_enabled} onClick={() => mark(setLists)({ ...lists, ipsum_enabled: !lists.ipsum_enabled })} aria-label={t('ipsum — список IP для VPN')} />}>
                <Field label="URL списка ipsum">
                  <input className={field} disabled={!lists.ipsum_enabled} value={lists.ipsum_url}
                    onChange={(e) => mark(setLists)({ ...lists, ipsum_url: e.target.value })} />
                </Field>
              </Section>

              <Section title="ru/cn — список напрямую" icon={ListChecks}
                right={<Switch on={lists.ru_enabled} onClick={() => mark(setLists)({ ...lists, ru_enabled: !lists.ru_enabled })} aria-label={t('ru/cn — список напрямую')} />}>
                <Field label="URL списка ru/cn">
                  <input className={field} disabled={!lists.ru_enabled} value={lists.ru_url}
                    onChange={(e) => mark(setLists)({ ...lists, ru_url: e.target.value })} />
                </Field>
              </Section>

              <Section title="Домены" icon={Globe}>
                <Field label="URL списка доменов для VPN" helpText="Скачиваемые домены направляются в VPN на этапе DNS-разрешения (dnsmasq).">
                  <input className={field} value={lists.vpn_domains_url}
                    onChange={(e) => mark(setLists)({ ...lists, vpn_domains_url: e.target.value })} />
                </Field>
                <Field label="URL списка доменов напрямую">
                  <input className={field} value={lists.ignore_domains_url}
                    onChange={(e) => mark(setLists)({ ...lists, ignore_domains_url: e.target.value })} />
                </Field>
              </Section>

              <Section title="Обход DPI" icon={ShieldCheck}
                right={<Switch on={lists.zapret_enabled} onClick={() => mark(setLists)({ ...lists, zapret_enabled: !lists.zapret_enabled })} aria-label={t('Обход DPI')} />}>
                <p className="text-xs text-muted-foreground">Использовать zapret. Пропускается автоматически, если zapret не установлен.</p>
              </Section>
            </>
          )}

          {tab === 'manual' && (
            <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
              <Section title="Подсети для VPN" icon={Network}
                desc="Удалённые подсети, которые должны идти через туннель — обычно LAN соседнего роутера для site-to-site (например 10.8.2.0/24).">
                <ListEditor values={manual.vpn_cidr} placeholder="10.8.2.0/24" onChange={(v) => mark(setManual)({ ...manual, vpn_cidr: v })} />
              </Section>
              <Section title="Подсети напрямую" icon={Network} desc="Подсети, которые держатся вне туннеля (всегда через WAN).">
                <ListEditor values={manual.direct_cidr} placeholder="192.168.50.0/24" onChange={(v) => mark(setManual)({ ...manual, direct_cidr: v })} />
              </Section>
              <Section title="Домены для VPN" icon={Globe}>
                <ListEditor values={manual.vpn_domain} placeholder="example.com" onChange={(v) => mark(setManual)({ ...manual, vpn_domain: v })} />
              </Section>
              <Section title="Домены напрямую" icon={Globe}>
                <ListEditor values={manual.direct_domain} placeholder="example.com" onChange={(v) => mark(setManual)({ ...manual, direct_domain: v })} />
              </Section>
            </div>
          )}

          {tab === 'endpoints' && (
            <Section title={`Туннели (с приоритетом) · ${endpoints.length}`} icon={Router}
              desc="Меньший номер приоритета — выше. Выбирайте интерфейсы, созданные в Сеть → Интерфейсы."
              right={<Button size="sm" variant="outline" onClick={() => mark(setEndpoints)([...endpoints, { sid: newId(), iface: ifaces[0] || '', priority: String(endpoints.length + 1), type: 'wg', isNew: true }])}>
                <Plus className="size-4" />Добавить туннель
              </Button>}>
              {endpoints.length === 0 ? (
                <p className="text-sm text-muted-foreground">Туннелей нет. Создайте интерфейс WireGuard/AmneziaWG в Сеть → Интерфейсы, затем добавьте его здесь.</p>
              ) : (
                <Table>
                  <TableHeader><TableRow><TableHead>Интерфейс</TableHead><TableHead>Приоритет</TableHead><TableHead>Тип</TableHead><TableHead /></TableRow></TableHeader>
                  <TableBody>
                    {endpoints.map((e, i) => (
                      <TableRow key={e.sid}>
                        <TableCell>
                          {e.type === 'singbox' ? (
                            <input className={cn(field, 'w-auto')} value={e.iface} placeholder="sb0"
                              onChange={(ev) => mark(setEndpoints)(endpoints.map((x, j) => j === i ? { ...x, iface: ev.target.value } : x))} />
                          ) : (
                            <select className={cn(field, 'w-auto')} value={e.iface}
                              onChange={(ev) => mark(setEndpoints)(endpoints.map((x, j) => j === i ? { ...x, iface: ev.target.value } : x))}>
                              {ifaces.length === 0 && <option value="">(интерфейсы WireGuard/AmneziaWG не найдены)</option>}
                              {ifaces.map((n) => <option key={n} value={n}>{n}</option>)}
                            </select>
                          )}
                        </TableCell>
                        <TableCell>
                          <input className={cn(field, 'w-20')} value={e.priority} placeholder="1"
                            onChange={(ev) => mark(setEndpoints)(endpoints.map((x, j) => j === i ? { ...x, priority: ev.target.value } : x))} />
                        </TableCell>
                        <TableCell>
                          <select className={cn(field, 'w-auto')} value={e.type}
                            onChange={(ev) => mark(setEndpoints)(endpoints.map((x, j) => j === i ? { ...x, type: ev.target.value } : x))}>
                            <option value="wg">WireGuard / AmneziaWG</option>
                            <option value="singbox">sing-box (VLESS/Hysteria2)</option>
                          </select>
                        </TableCell>
                        <TableCell>
                          <Button size="icon" variant="destructive" onClick={() => mark(setEndpoints)(endpoints.filter((_, j) => j !== i))} aria-label={t('Delete')} title={t('Delete')}>
                            <XIcon className="size-4" />
                          </Button>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </Section>
          )}

          {tab === 'devices' && (
            <Section title={`Правила для отдельных устройств · ${devices.length}`} icon={MonitorSmartphone}
              desc="Привяжите устройство LAN к VPN или к прямому каналу по его IP."
              right={<Button size="sm" variant="outline" onClick={() => mark(setDevices)([...devices, { sid: newId(), ip: '', mode: 'vpn', isNew: true }])}>
                <Plus className="size-4" />Добавить устройство
              </Button>}>
              {devices.length === 0 ? (
                <p className="text-sm text-muted-foreground">Правил пока нет.</p>
              ) : (
                <Table>
                  <TableHeader><TableRow><TableHead>IP устройства</TableHead><TableHead>Маршрут</TableHead><TableHead /></TableRow></TableHeader>
                  <TableBody>
                    {devices.map((d, i) => (
                      <TableRow key={d.sid}>
                        <TableCell>
                          <input className={field} list="splify-host-hints" value={d.ip} placeholder="192.168.1.50"
                            onChange={(ev) => mark(setDevices)(devices.map((x, j) => j === i ? { ...x, ip: ev.target.value } : x))} />
                        </TableCell>
                        <TableCell>
                          <select className={cn(field, 'w-auto')} value={d.mode}
                            onChange={(ev) => mark(setDevices)(devices.map((x, j) => j === i ? { ...x, mode: ev.target.value } : x))}>
                            <option value="vpn">Через VPN</option>
                            <option value="direct">Напрямую</option>
                          </select>
                        </TableCell>
                        <TableCell>
                          <Button size="icon" variant="destructive" onClick={() => mark(setDevices)(devices.filter((_, j) => j !== i))} aria-label={t('Delete')} title={t('Delete')}>
                            <XIcon className="size-4" />
                          </Button>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
              <datalist id="splify-host-hints">
                {hostHints.map(([ip, label]) => <option key={ip} value={ip}>{label}</option>)}
              </datalist>
            </Section>
          )}
        </div>
      </div>
    </div>
  )
}

declare global {
  interface Window { __splifyHostHints?: any }
}
