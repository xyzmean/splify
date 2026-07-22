/**
 * Cloudflare Worker: reverse proxy → api.cloudflareclient.com
 *
 * Обходит блокировку API регистрации WARP (api.cloudflareclient.com недоступен
 * у ряда провайдеров, а *.workers.dev — доступен). Используется easyinstall.sh:
 *   WORKER="https://<your-subdomain>.workers.dev"
 *   curl "$WORKER/v0i1909051800/reg" …   →   api.cloudflareclient.com/v0i1909051800/reg
 *
 * Деплой (вариант A — dashboard):
 *   1. https://dash.cloudflare.com → Workers & Pages → Create → Worker
 *   2. имя: warp-api-proxy, вставьте этот код, Deploy.
 *   3. Скопируйте URL вида https://warp-api-proxy.<acct>.workers.dev
 *
 * Деплой (вариант B — wrangler):
 *   npx wrangler deploy warp-api-proxy.worker.js --name warp-api-proxy
 *
 * Никаких секретов не хранит — просто прокси. Безопасность: Worker публичный,
 * но он лишь форвардит запросы регистрации WARP; ничьих ключей у него нет
 * (ключи генерируются на роутере и уходят транзитом).
 */

const UPSTREAM = 'https://api.cloudflareclient.com'

export default {
  async fetch(req) {
    const url = new URL(req.url)

    // health check — чтобы easyinstall мог проверить, что Worker жив.
    if (url.pathname === '/' || url.pathname === '/ping') {
      return new Response('warp-api-proxy ok\n', { status: 200,
        headers: { 'content-type': 'text/plain' } })
    }

    // Проброс на upstream: путь + query сохраняются.
    const target = UPSTREAM + url.pathname + url.search

    // Клонием запрос, сохраняя метод/тело/заголовки. Подменяем Origin/Host
    // не нужно — fetch сам выставит Host по target. CF API требует именно
    // User-Agent: okhttp/3.12.1 — он приходит от клиента, не трогаем.
    const init = {
      method: req.method,
      headers: req.headers,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : req.body,
      redirect: 'manual',
    }

    try {
      const r = await fetch(target, init)
      // Возвращаем ответ как есть — статус, заголовки, тело.
      const body = await r.arrayBuffer()
      return new Response(body, { status: r.status, headers: r.headers })
    } catch (e) {
      return new Response('upstream error: ' + e.message, { status: 502 })
    }
  },
}
