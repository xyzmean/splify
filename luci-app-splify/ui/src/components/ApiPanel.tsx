import { useEffect, useState } from 'react'
import { rpc, type ApiInfo } from '@/lib/rpc'
import { fmtUnix } from '@/lib/format'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { Plug, Radio, KeyRound, Eye, EyeOff, RefreshCw, Tag } from 'lucide-react'

function notify(msg: string, kind: 'info' | 'warning' | 'error' = 'info') {
  try { if (window.ui?.addNotification) { window.ui.addNotification(null, window.L ? window.L.dom.create('p', {}, msg) : msg, kind); return } } catch { /* */ }
  // eslint-disable-next-line no-console
  console.log('[splify]', kind, msg)
}

const field = 'w-full rounded-md border border-input bg-background px-2.5 py-1.5 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring'
const lbl = 'mb-1 block text-xs text-muted-foreground'

export default function ApiPanel() {
  const [info, setInfo] = useState<ApiInfo | null>(null)
  const [connJson, setConnJson] = useState('')
  const [busy, setBusy] = useState('')
  const [showToken, setShowToken] = useState(false)
  const [revealedToken, setRevealedToken] = useState('')
  const [ci, setCi] = useState('')
  const [ce, setCe] = useState('')
  const [interval, setIntervalV] = useState('')
  const [allow, setAllow] = useState('')
  const [nodeId, setNodeId] = useState('')

  const load = async () => {
    try {
      const i = await rpc.apiGet()
      setInfo(i)
      setCi(i.control_internal || ''); setCe(i.control_external || '')
      setIntervalV(i.interval || ''); setAllow(i.allow_subnet || '')
      setNodeId(i.node_id || '')
    } catch (e: any) { notify('Не удалось загрузить настройки API: ' + (e?.message || e), 'error') }
  }
  useEffect(() => { load() }, [])

  const NODE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
  async function saveNode() {
    const n = nodeId.trim()
    if (!NODE_RE.test(n)) { notify('Имя ноды: латиница/цифры и . _ - , без пробелов, до 64 символов', 'warning'); return }
    setBusy('node')
    try { await rpc.apiSet({ node_id: n }); notify('Имя ноды сохранено'); load() }
    catch (e: any) { notify('Ошибка: ' + (e?.message || e), 'error') }
    finally { setBusy('') }
  }

  async function connect() {
    if (!connJson.trim()) return
    setBusy('connect')
    try {
      const res = await rpc.connect(connJson.trim())
      if (res?.ok) { notify(`Подключено к панели (${res.via}), node_id: ${res.node_id}`); setConnJson(''); load() }
      else notify('Подключение не удалось: ' + (res?.error || JSON.stringify(res)), 'warning')
    } catch (e: any) { notify('Ошибка подключения: ' + (e?.message || e), 'error') }
    finally { setBusy('') }
  }

  async function saveSettings(extra: Partial<Record<string, string>> = {}) {
    setBusy('save')
    try {
      await rpc.apiSet({ control_internal: ci, control_external: ce, interval, allow_subnet: allow, ...extra })
      notify('Настройки сохранены'); load()
    } catch (e: any) { notify('Ошибка сохранения: ' + (e?.message || e), 'error') }
    finally { setBusy('') }
  }

  async function toggle(which: 'agent_enabled' | 'enabled', val: boolean) {
    setBusy(which)
    try { await rpc.apiSet({ [which]: val ? '1' : '0' }); notify('Сохранено'); load() }
    catch (e: any) { notify('Ошибка: ' + (e?.message || e), 'error') }
    finally { setBusy('') }
  }

  async function regen() {
    if (!window.confirm('Перевыпустить токен? Старый перестанет работать — обновите его на панели управления.')) return
    setBusy('regen')
    try { const r = await rpc.tokenRegen(); notify('Новый токен: ' + r.token); setRevealedToken(r.token); setShowToken(true); load() }
    catch (e: any) { notify('Ошибка: ' + (e?.message || e), 'error') }
    finally { setBusy('') }
  }

  // The token is masked in api_get (read ACL); fetch it on demand via the
  // write-gated api_token only when the operator chooses to reveal it.
  async function toggleToken() {
    if (showToken) { setShowToken(false); return }
    try {
      if (!revealedToken) { const r = await rpc.apiToken(); setRevealedToken(r.token || '') }
      setShowToken(true)
    } catch (e: any) { notify('Не удалось показать токен: ' + (e?.message || e), 'error') }
  }

  async function enroll() {
    setBusy('enroll')
    try { const r = await rpc.enroll(); if (r?.ok) notify(`Зарегистрировано (${r.via})`); else notify('Enroll: ' + (r?.error || JSON.stringify(r)), 'warning'); load() }
    catch (e: any) { notify('Ошибка enroll: ' + (e?.message || e), 'error') }
    finally { setBusy('') }
  }

  if (!info) return <Card><CardContent className="p-6 text-muted-foreground">Загрузка…</CardContent></Card>
  const enrolled = info.enrolled === '1'
  const agentOn = info.agent_enabled === '1'
  const restOn = info.enabled === '1'

  return (
    <div className="space-y-4">
      {/* connection status — KPI blocks */}
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <StatTile label="Подключено" value={<OkBadge ok={enrolled}>{enrolled ? 'да' : 'нет'}</OkBadge>} />
        <StatTile label="Агент" value={<OkBadge ok={info.agent_running}>{info.agent_running ? 'работает' : agentOn ? 'запускается' : 'выкл'}</OkBadge>} />
        <StatTile label="Node ID" value={<code className="text-sm">{info.node_id || '—'}</code>} />
        <StatTile label="Последний опрос" value={<span className="text-sm font-medium">{fmtUnix(info.last_poll)}</span>}
          sub={info.last_result || undefined} />
      </div>

      {/* node name (node_id) */}
      <Card>
        <CardHeader className="p-4 pb-2"><CardTitle className="flex items-center gap-2 text-sm"><Tag className="size-4" />Имя ноды</CardTitle></CardHeader>
        <CardContent className="p-4 pt-2">
          <p className="mb-2 text-xs text-muted-foreground">Под этим именем роутер виден в панели. Латиница/цифры и <code>. _ -</code>, без пробелов, до 64 символов. Задайте его <b>до подключения</b> — это самое простое.</p>
          <div className="flex gap-2">
            <input className={cn(field, 'max-w-xs')} value={nodeId} onChange={(e) => setNodeId(e.target.value)} placeholder="office-rt1" />
            <Button size="sm" variant="outline" disabled={!!busy} onClick={saveNode}>{busy === 'node' ? 'Сохраняю…' : 'Сохранить имя'}</Button>
          </div>
          {enrolled && <p className="mt-2 text-xs text-amber-600 dark:text-amber-400">Нода уже подключена. После смены имени нажмите «Перерегистрировать» — в панели появится новая запись с новым именем, старую можно удалить.</p>}
        </CardContent>
      </Card>

      {/* connect via connection JSON */}
      <Card>
        <CardHeader className="p-4 pb-2"><CardTitle className="flex items-center gap-2 text-sm"><Plug className="size-4" />Подключить к панели</CardTitle></CardHeader>
        <CardContent className="p-4 pt-2">
          <p className="mb-2 text-xs text-muted-foreground">Вставьте «JSON подключения» из панели управления (внешний + внутренний адрес и ключ доступа). Роутер сгенерирует свой ключ связи и зарегистрируется.</p>
          <textarea className={cn(field, 'min-h-[90px] font-mono text-xs')} value={connJson} onChange={(e) => setConnJson(e.target.value)}
            placeholder={'{"internal":"http://10.8.0.1:8080","external":"https://vpn.example.net:8443","access_key":"…"}'} />
          <div className="mt-2 flex gap-2">
            <Button size="sm" disabled={!!busy} onClick={connect}>{busy === 'connect' ? 'Подключаю…' : 'Подключить'}</Button>
            {enrolled && info.has_access_key && <Button size="sm" variant="outline" disabled={!!busy} onClick={enroll}>Перерегистрировать</Button>}
          </div>
        </CardContent>
      </Card>

      {/* outbound agent */}
      <Card>
        <CardHeader className="flex-row items-center justify-between space-y-0 p-4 pb-2">
          <CardTitle className="flex items-center gap-2 text-sm"><Radio className="size-4" />Исходящий агент (CGNAT / упавший туннель)</CardTitle>
          <Switch on={agentOn} disabled={!!busy} onClick={() => toggle('agent_enabled', !agentOn)} />
        </CardHeader>
        <CardContent className="p-4 pt-2">
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            <div><span className={lbl}>Внутренний URL панели (через туннель)</span>
              <input className={field} value={ci} onChange={(e) => setCi(e.target.value)} placeholder="http://10.8.0.1:8080" /></div>
            <div><span className={lbl}>Внешний URL панели (через WAN)</span>
              <input className={field} value={ce} onChange={(e) => setCe(e.target.value)} placeholder="https://vpn.example.net:8443" /></div>
            <div><span className={lbl}>Интервал опроса (сек)</span>
              <input className={cn(field, 'w-32')} value={interval} onChange={(e) => setIntervalV(e.target.value)} placeholder="60" /></div>
          </div>
          <p className="mt-2 text-xs text-muted-foreground">Внутренний адрес пробуется первым (приватно, через туннель); внешний — резерв по WAN, когда туннель недоступен.</p>
          <div className="mt-3"><Button size="sm" variant="outline" disabled={!!busy} onClick={() => saveSettings()}>{busy === 'save' ? 'Сохраняю…' : 'Сохранить адреса'}</Button></div>
        </CardContent>
      </Card>

      {/* inbound REST */}
      <Card>
        <CardHeader className="flex-row items-center justify-between space-y-0 p-4 pb-2">
          <CardTitle className="flex items-center gap-2 text-sm"><KeyRound className="size-4" />Входящий REST API (LAN / WG)</CardTitle>
          <Switch on={restOn} disabled={!!busy} onClick={() => toggle('enabled', !restOn)} />
        </CardHeader>
        <CardContent className="p-4 pt-2">
          <p className="mb-3 text-xs text-muted-foreground">Доступен по адресу <code>/cgi-bin/splify-api</code> с авторизацией по токену. Не открывайте его в публичный интернет — он для LAN / WG-сети.</p>
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            <div><span className={lbl}>Токен доступа</span>
              <div className="flex gap-2">
                <input className={cn(field, 'font-mono text-xs')} type={showToken ? 'text' : 'password'} value={showToken ? revealedToken : (info.has_token ? '••••••••••••••••' : '')} readOnly />
                <Button size="sm" variant="outline" onClick={toggleToken}>{showToken ? <EyeOff className="size-4" /> : <Eye className="size-4" />}</Button>
                <Button size="sm" variant="outline" disabled={!!busy} onClick={regen}><RefreshCw className="size-4" />Сменить</Button>
              </div></div>
            <div><span className={lbl}>Ограничение по подсети (префикс, опц.)</span>
              <div className="flex gap-2">
                <input className={field} value={allow} onChange={(e) => setAllow(e.target.value)} placeholder="10.8.0." />
                <Button size="sm" variant="outline" disabled={!!busy} onClick={() => saveSettings()}>Сохранить</Button>
              </div></div>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}

function StatTile({ label, value, sub }: { label: string; value: React.ReactNode; sub?: React.ReactNode }) {
  return (
    <Card>
      <CardContent className="flex flex-col gap-1 p-4">
        <div className="text-xs text-muted-foreground">{label}</div>
        <div className="font-semibold">{value}</div>
        {sub != null && sub !== '' && <div className="truncate text-xs text-muted-foreground">{sub}</div>}
      </CardContent>
    </Card>
  )
}
function OkBadge({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return <Badge className={ok ? 'border-transparent bg-emerald-500 text-white' : 'border-transparent bg-muted-foreground/40 text-white'}>{children}</Badge>
}
function Switch({ on, onClick, disabled }: { on: boolean; onClick: () => void; disabled?: boolean }) {
  return (
    <button onClick={onClick} disabled={disabled}
      className={cn('relative h-6 w-11 rounded-full transition disabled:opacity-50', on ? 'bg-emerald-500' : 'bg-muted-foreground/30')}>
      <span className={cn('absolute left-0.5 top-0.5 size-5 rounded-full bg-white transition-transform', on && 'translate-x-5')} />
    </button>
  )
}
