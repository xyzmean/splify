import { useEffect, useState } from 'react'
import { rpc } from '@/lib/rpc'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { Settings2, FileDown, Eye, KeyRound } from 'lucide-react'

// Small numeric obfuscation knobs (rendered as a compact grid).
const NUM_KEYS = ['jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'h1', 'h2', 'h3', 'h4', 'itime'] as const
// AWG 1.5 junk-packet definitions — long values, rendered full-width.
const JUNK_KEYS = ['i1', 'i2', 'i3', 'i4', 'i5', 'j1', 'j2', 'j3'] as const
const ALL_AWG = [...NUM_KEYS, ...JUNK_KEYS]

type Form = Record<string, string>

function notify(msg: string, kind: 'info' | 'warning' | 'error' = 'info') {
  try { if (window.ui?.addNotification) { window.ui.addNotification(null, window.L ? window.L.dom.create('p', {}, msg) : msg, kind); return } } catch { /* */ }
  // eslint-disable-next-line no-console
  console.log('[splify]', kind, msg)
}

const field = 'w-full rounded-md border border-input bg-background px-2.5 py-1.5 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring'
const lbl = 'mb-1 block text-xs text-muted-foreground'

export default function WgPanel() {
  const [wg, setWg] = useState<Record<string, any>>({})
  const [iface, setIface] = useState('')
  const [form, setForm] = useState<Form>({})
  const [conf, setConf] = useState('')
  const [busy, setBusy] = useState('')
  const [revealed, setRevealed] = useState(false)
  const [showJunk, setShowJunk] = useState(false)
  const [err, setErr] = useState('')

  const load = async () => {
    try {
      const snap = await rpc.exportCfg(0)
      const w = snap?.wg || {}
      setWg(w)
      const names = Object.keys(w)
      const sel = iface && names.includes(iface) ? iface : names[0] || ''
      setIface(sel)
      if (sel) fillForm(w[sel])
      setErr('')
    } catch (e: any) { setErr(e?.message || String(e)) }
  }
  useEffect(() => { load() }, []) // eslint-disable-line react-hooks/exhaustive-deps

  function fillForm(d: any) {
    const peer = (d?.peers || [])[0] || {}
    const f: Form = {
      endpoint_host: peer.endpoint_host || '',
      endpoint_port: peer.endpoint_port || '',
      allowed_ips: (peer.allowed_ips || []).join(', '),
      keepalive: peer.persistent_keepalive || '',
      dns: (d?.dns || []).join(', '),
      addresses: (d?.addresses || []).join(', '),
      private_key: '',
    }
    for (const k of ALL_AWG) f[k] = (d?.awg || {})[k] || ''
    setForm(f)
    setRevealed(false)
    // auto-open the junk section if any of those keys are already set
    setShowJunk(JUNK_KEYS.some((k) => (d?.awg || {})[k]))
  }

  function pick(name: string) { setIface(name); fillForm(wg[name]) }
  const set = (k: string, v: string) => setForm((f) => ({ ...f, [k]: v }))

  async function reveal() {
    try {
      const d = await rpc.wgGet(iface, 1)
      set('private_key', d?.private_key || '')
      setRevealed(true)
    } catch (e: any) { notify('Не удалось показать ключ: ' + (e?.message || e), 'error') }
  }

  async function save() {
    if (!iface) return
    if (!window.confirm(`Сохранить параметры ${iface}? Туннель будет переподключён, чтобы применить изменения.`)) return
    setBusy('save')
    try {
      const cur = wg[iface] || {}
      const payload: any = {}
      const awg: Form = {}
      for (const k of ALL_AWG) if (form[k] !== '') awg[k] = form[k]
      if (Object.keys(awg).length) payload.awg = awg
      if (form.dns.trim()) payload.dns = form.dns.split(/[\s,]+/).filter(Boolean)
      if (form.addresses.trim()) payload.addresses = form.addresses.split(/[\s,]+/).filter(Boolean)
      if (form.private_key.trim()) payload.private_key = form.private_key.trim()
      // rebuild peers (replace-wholesale; PSK preserved server-side by public_key)
      payload.peers = (cur.peers && cur.peers.length ? cur.peers : [{}]).map((pr: any, i: number) => {
        if (i !== 0) return pr
        const np = { ...pr }
        if (form.endpoint_host) np.endpoint_host = form.endpoint_host
        if (form.endpoint_port) np.endpoint_port = form.endpoint_port
        if (form.keepalive !== '') np.persistent_keepalive = form.keepalive
        if (form.allowed_ips.trim()) np.allowed_ips = form.allowed_ips.split(/[\s,]+/).filter(Boolean)
        delete np.has_preshared_key
        return np
      })
      const res = await rpc.wgSet(iface, payload)
      if (res?.ok) { notify(`Параметры ${iface} сохранены, туннель переподключён`); load() }
      else notify('Сохранение отклонено: ' + JSON.stringify(res), 'warning')
    } catch (e: any) { notify('Ошибка сохранения: ' + (e?.message || e), 'error') }
    finally { setBusy('') }
  }

  async function importConf() {
    if (!iface || !conf.trim()) return
    if (!window.confirm(`Импортировать .conf в ${iface}? Существующие peers будут заменены, туннель переподключён.`)) return
    setBusy('import')
    try {
      const res = await rpc.wgImport(iface, conf)
      if (res?.ok) { notify(`Конфиг импортирован в ${iface}`); setConf(''); load() }
      else notify('Импорт отклонён: ' + (res?.error || JSON.stringify(res)), 'warning')
    } catch (e: any) { notify('Ошибка импорта: ' + (e?.message || e), 'error') }
    finally { setBusy('') }
  }

  if (err) return <Card><CardContent className="p-6 text-rose-500">Не удалось загрузить конфигурацию: {err}</CardContent></Card>
  const names = Object.keys(wg)
  if (!names.length) return <Card><CardContent className="p-6 text-muted-foreground">Интерфейсы WireGuard/AmneziaWG не найдены. Создайте их в Сеть → Интерфейсы.</CardContent></Card>
  const cur = wg[iface] || {}
  const peer = (cur.peers || [])[0] || {}

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader className="flex-row flex-wrap items-center gap-3 space-y-0 p-4 pb-2">
          <CardTitle className="flex items-center gap-2 text-sm"><Settings2 className="size-4" />Параметры AmneziaWG / WireGuard</CardTitle>
          {names.length > 1 && (
            <select className={cn(field, 'w-auto')} value={iface} onChange={(e) => pick(e.target.value)}>
              {names.map((n) => <option key={n} value={n}>{n}</option>)}
            </select>
          )}
          <Badge variant="secondary">{cur.proto}</Badge>
          <Badge variant={cur.has_private_key ? 'secondary' : 'outline'}>{cur.has_private_key ? 'ключ задан' : 'без ключа'}</Badge>
          <div className="flex-1" />
          <Button size="sm" disabled={!!busy} onClick={save}>{busy === 'save' ? 'Сохраняю…' : 'Сохранить и переподключить'}</Button>
        </CardHeader>
        <CardContent className="space-y-4 p-4 pt-2">
          {/* endpoint / peer block */}
          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            <div><span className={lbl}>Endpoint (сервер)</span>
              <div className="flex gap-2">
                <input className={field} value={form.endpoint_host || ''} onChange={(e) => set('endpoint_host', e.target.value)} placeholder="45.144.53.1" />
                <input className={cn(field, 'w-24')} value={form.endpoint_port || ''} onChange={(e) => set('endpoint_port', e.target.value)} placeholder="порт" />
              </div>
            </div>
            <div><span className={lbl}>AllowedIPs (через запятую)</span>
              <input className={field} value={form.allowed_ips || ''} onChange={(e) => set('allowed_ips', e.target.value)} placeholder="0.0.0.0/0" />
            </div>
            <div><span className={lbl}>Адреса интерфейса</span>
              <input className={field} value={form.addresses || ''} onChange={(e) => set('addresses', e.target.value)} placeholder="10.8.0.2/24" />
            </div>
            <div><span className={lbl}>DNS</span>
              <input className={field} value={form.dns || ''} onChange={(e) => set('dns', e.target.value)} placeholder="8.8.8.8, 8.8.4.4" />
            </div>
            <div><span className={lbl}>Persistent keepalive</span>
              <input className={cn(field, 'w-32')} value={form.keepalive || ''} onChange={(e) => set('keepalive', e.target.value)} placeholder="25" />
            </div>
            <div><span className={lbl}>Public key пира</span>
              <input className={cn(field, 'font-mono text-xs')} value={peer.public_key || ''} readOnly />
            </div>
          </div>

          {/* obfuscation numeric knobs */}
          <div>
            <span className={lbl}>Обфускация AmneziaWG — счётчики</span>
            <div className="grid grid-cols-3 gap-2 sm:grid-cols-4 lg:grid-cols-6">
              {NUM_KEYS.map((k) => (
                <div key={k}><span className={lbl}>{k}</span>
                  <input className={field} value={form[k] || ''} onChange={(e) => set(k, e.target.value)} />
                </div>
              ))}
            </div>
          </div>

          {/* junk packets I1-I5 / J1-J3 (long) */}
          <div className="rounded-lg border bg-muted/30 p-3">
            <button type="button" onClick={() => setShowJunk((v) => !v)} className="flex w-full items-center justify-between text-left text-sm font-medium">
              <span>Junk-пакеты (AWG 1.5): I1–I5, J1–J3</span>
              <span className="text-xs text-muted-foreground">{showJunk ? 'свернуть ▲' : 'развернуть ▼'}</span>
            </button>
            {showJunk && (
              <div className="mt-3 space-y-2">
                <p className="text-xs text-muted-foreground">Длинные junk-сигнатуры из конфига AmneziaWG. Оставьте поле пустым, чтобы не менять его. Эти же поля доступны по API и при импорте <code>.conf</code>.</p>
                {JUNK_KEYS.map((k) => (
                  <div key={k}>
                    <span className={lbl}>{k.toUpperCase()}</span>
                    <input className={cn(field, 'font-mono text-xs')} value={form[k] || ''} onChange={(e) => set(k, e.target.value)}
                      placeholder={k.startsWith('i') ? '<b 0xf1…> сигнатура junk-пакета' : 'размер junk-пакета'} />
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* private key */}
          <div>
            <span className={lbl}><KeyRound className="mr-1 inline size-3.5" />Приватный ключ интерфейса</span>
            <div className="flex gap-2">
              <input className={cn(field, 'font-mono text-xs')} type={revealed ? 'text' : 'password'}
                value={revealed ? (form.private_key || '') : (cur.has_private_key ? '••••••••••••••••' : (form.private_key || ''))}
                onChange={(e) => set('private_key', e.target.value)}
                readOnly={!revealed && cur.has_private_key}
                placeholder={cur.has_private_key ? '(не менять)' : 'не задан'} />
              {!revealed && cur.has_private_key && <Button size="sm" variant="outline" onClick={reveal}><Eye className="size-4" />Показать</Button>}
            </div>
            <p className="mt-1 text-xs text-muted-foreground">Оставьте поле пустым, чтобы не менять текущий ключ.</p>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="p-4 pb-2">
          <CardTitle className="flex items-center gap-2 text-sm"><FileDown className="size-4" />Импорт .conf (AmneziaWG / WireGuard)</CardTitle>
        </CardHeader>
        <CardContent className="p-4 pt-2">
          <p className="mb-2 text-xs text-muted-foreground">Вставьте файл клиента (как выгружает AmneziaVPN / wg-quick). Секции [Interface] и [Peer] — включая I1–I5 / J1–J3 — будут применены к {iface}.</p>
          <textarea className={cn(field, 'min-h-[160px] font-mono text-xs')} value={conf} onChange={(e) => setConf(e.target.value)}
            placeholder={'[Interface]\nPrivateKey = …\nJc = 4\nI1 = <b 0xf1…>\n[Peer]\nPublicKey = …\nEndpoint = host:port\nAllowedIPs = 0.0.0.0/0'} />
          <div className="mt-2"><Button size="sm" disabled={!!busy} onClick={importConf}>{busy === 'import' ? 'Импортирую…' : 'Импортировать и переподключить'}</Button></div>
        </CardContent>
      </Card>
    </div>
  )
}
