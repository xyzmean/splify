import { useEffect, useState } from 'react'
import { rpc, type SingboxIface } from '@/lib/rpc'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { notify } from '@/lib/notify'
import { Waypoints, FileDown } from 'lucide-react'

const field = 'w-full rounded-md border border-input bg-background px-2.5 py-1.5 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring'
const lbl = 'mb-1 block text-xs text-muted-foreground'

const IFACE_RE = /^[A-Za-z0-9_-]{1,15}$/

export default function SingboxPanel() {
  const [entries, setEntries] = useState<Record<string, SingboxIface>>({})
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState('')
  const [newIface, setNewIface] = useState('')
  const [uriText, setUriText] = useState('')
  const [busy, setBusy] = useState('')

  const load = async () => {
    setLoading(true)
    try {
      const snap = await rpc.exportCfg(0)
      setEntries(snap?.singbox || {})
      setLoadError('')
    } catch (e: any) {
      const msg = e?.message || String(e)
      setLoadError(msg)
      notify('Не удалось загрузить sing-box конфигурацию: ' + msg, 'error')
    } finally {
      setLoading(false)
    }
  }
  useEffect(() => { load() }, []) // eslint-disable-line react-hooks/exhaustive-deps

  async function importUri() {
    const name = newIface.trim()
    if (!IFACE_RE.test(name)) { notify('Имя туннеля: латиница/цифры и _ - , до 15 символов', 'warning'); return }
    if (!uriText.trim()) return
    setBusy('import')
    try {
      const res = await rpc.singboxImport(name, uriText.trim())
      if (res?.ok) { notify(`Ссылка импортирована в ${name}`); setUriText(''); load() }
      else notify('Импорт отклонён: ' + (res?.error || JSON.stringify(res)), 'warning')
    } catch (e: any) { notify('Ошибка импорта: ' + (e?.message || e), 'error') }
    finally { setBusy('') }
  }

  if (loadError && !Object.keys(entries).length) return (
    <Card><CardContent className="flex items-center justify-between gap-3 p-6 text-destructive">
      <span>Не удалось загрузить sing-box конфигурацию: {loadError}</span>
      <Button size="sm" variant="outline" onClick={() => load()}>Повторить</Button>
    </CardContent></Card>
  )
  if (loading && !Object.keys(entries).length) return <Card><CardContent className="p-6 text-muted-foreground">Загрузка…</CardContent></Card>

  const names = Object.keys(entries)

  return (
    <div className="space-y-4">
      {names.length ? (
        names.map((name) => {
          const e = entries[name]
          return (
            <Card key={name}>
              <CardHeader className="flex-row flex-wrap items-center gap-3 space-y-0 p-4 pb-2">
                <CardTitle className="flex items-center gap-2 text-[1.1rem] font-normal"><Waypoints className="size-4" />{e.name || e.iface || name}</CardTitle>
                <Badge variant="secondary">{e.protocol}</Badge>
                {e.security && <Badge variant="outline">{e.security}</Badge>}
                {e.protocol === 'vless' && e.network && <Badge variant="outline">{e.network}</Badge>}
              </CardHeader>
              <CardContent className="space-y-1 p-4 pt-2 text-sm">
                <div><span className="text-muted-foreground">Интерфейс: </span>{e.iface || name}</div>
                <div><span className="text-muted-foreground">Сервер: </span>{e.server}:{e.port}</div>
                <p className="mt-2 text-xs text-muted-foreground">Изменить: вставьте новую ссылку ниже с тем же названием туннеля.</p>
              </CardContent>
            </Card>
          )
        })
      ) : (
        <Card><CardContent className="p-6 text-muted-foreground">
          Sing-box эндпоинтов пока нет. Вставьте vless:// или hysteria2:// ссылку ниже, чтобы добавить.
        </CardContent></Card>
      )}

      <Card>
        <CardHeader className="p-4 pb-2">
          <CardTitle className="flex items-center gap-2 text-[1.1rem] font-normal"><FileDown className="size-4" />Импорт ссылки</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 p-4 pt-2">
          <div>
            <span className={lbl}>Название туннеля</span>
            <input className={cn(field, 'max-w-[200px]')} value={newIface} onChange={(e) => setNewIface(e.target.value)} placeholder="sb0" />
            <p className="mt-1 text-xs text-muted-foreground">Короткое синтетическое имя (латиница/цифры/._-, до 15 символов) — используется как внутреннее имя туннеля.</p>
            {newIface.trim() !== '' && !IFACE_RE.test(newIface.trim()) && (
              <p className="mt-1 text-xs text-destructive">Недопустимое имя: латиница/цифры и _ -, до 15 символов.</p>
            )}
          </div>
          <div>
            <span className={lbl}>Ссылка (vless:// или hysteria2://)</span>
            <textarea className={cn(field, 'min-h-[100px] font-mono text-xs')} value={uriText} onChange={(e) => setUriText(e.target.value)}
              placeholder={'vless://...\nили\nhysteria2://...'} />
          </div>
          <Button size="sm" disabled={!!busy} onClick={importUri}>{busy === 'import' ? 'Импортирую…' : 'Импортировать'}</Button>
          <p className="text-xs text-muted-foreground">
            Чтобы туннель участвовал в переключении при сбое, добавьте его в «Туннели» (раздел «Дополнительно») — импорт ссылки здесь только создаёт саму конфигурацию sing-box.
          </p>
        </CardContent>
      </Card>
    </div>
  )
}
