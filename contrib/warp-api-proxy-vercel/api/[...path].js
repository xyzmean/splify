/**
 * Vercel Serverless Function: reverse proxy → api.cloudflareclient.com
 *
 * Обходит блокировку API регистрации WARP. Worker на *.workers.dev упирается в
 * Cloudflare rate-limit 1015 (shared egress IP), а Vercel ходит с AWS-диапазонов
 * и лимита не ловит. Используется easyinstall.sh через WORKER_URL.
 *
 * Деплой (1 минута):
 *   1. https://vercel.com → New Project → Import Git Repository (или blank).
 *   2. В корне положите этот файл по пути api/[...path].js и package.json ниже.
 *   3. Deploy. Скопируйте URL вида https://<app>.vercel.app.
 *   4. easyinstall: WORKER_URL="https://<app>.vercel.app" sh easyinstall.sh
 *
 * Catch-all route /api/[...path] пробрасывает любой путь на апстрим:
 *   POST   /api/reg                         → api.cloudflareclient.com/v0a1922/reg
 *   PATCH  /api/reg/<id>                    → api.cloudflareclient.com/v0a1922/reg/<id>
 *   PUT    /api/reg/<id>/account            → api.cloudflareclient.com/v0a1922/reg/<id>/account
 * (префикс /v0a1922 добавляется здесь — easyinstall шлёт короткие пути).
 *
 * Никаких секретов не хранит — просто прокси.
 */

const UPSTREAM = 'https://api.cloudflareclient.com'
const API_VERSION = 'v0a1922'

export default async function handler(req) {
  const url = new URL(req.url)

  // Health check.
  if (url.pathname === '/' || url.pathname === '/api' || url.pathname === '/api/') {
    return new Response('warp-api-proxy (vercel) ok\n', {
      status: 200,
      headers: { 'content-type': 'text/plain' },
    })
  }

  // Normalize: strip leading /api/, then prepend the API version.
  let path = url.pathname.replace(/^\/api\//, '').replace(/^\//, '')
  const target = `${UPSTREAM}/${API_VERSION}/${path}${url.search}`

  // Clone headers; drop host (fetch sets it from target). Keep CF-Client-Version
  // and User-Agent as the client sent them — Cloudflare keys rate-limit policy
  // partly on these, so wgcf-style okhttp/3.12.1 + a-6.3-1922 must pass through.
  const headers = new Headers(req.headers)
  headers.delete('host')
  headers.delete('content-length')

  const init = {
    method: req.method,
    headers,
    body: ['GET', 'HEAD'].includes(req.method) ? undefined : req.body,
    redirect: 'manual',
  }

  try {
    const r = await fetch(target, init)
    const body = await r.arrayBuffer()
    // Pass-through status + headers; strip hop-by-hop as needed.
    const out = new Response(body, { status: r.status, headers: r.headers })
    return out
  } catch (e) {
    return new Response('upstream error: ' + e.message, { status: 502 })
  }
}
