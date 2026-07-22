# warp-api-proxy (Vercel)

Reverse proxy → `api.cloudflareclient.com` для регистрации Cloudflare WARP,
обходящий блокировку API и rate-limit.

## Зачем

`api.cloudflareclient.com` заблокирован рядом провайдеров, а CF Worker-прокси
на `*.workers.dev` упирается в Cloudflare error 1015 (rate-limit на shared
egress IP). Vercel ходит в интернет с AWS-диапазонов — не блокируется и лимита
не ловит.

## Деплой (1 минута)

1. https://vercel.com → **Add New… → Project → Import Git Repository** (или
   **Create Blank**, затем перетащите папку).
2. В корне репозитория/папки должно быть:
   - `api/[...path].js` — сама serverless-функция,
   - `package.json`.
3. **Deploy**. Скопируйте URL вида `https://<app>.vercel.app`.
4. Готово. Проверьте: `curl https://<app>.vercel.app/api/` →
   `warp-api-proxy (vercel) ok`.

## Использование

Передайте URL в `easyinstall.sh` через `WORKER_URL`:

```sh
wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/easyinstall.sh \
  | WORKER_URL="https://<app>.vercel.app" sh
```

## Маршруты

Catch-all `/api/[...path]` пробрасывает путь на апстрим с префиксом версии
`v0a1922` (формат утилиты wgcf):

| Запрос | Апстрим |
|---|---|
| `POST /api/reg` | `POST api.cloudflareclient.com/v0a1922/reg` |
| `PATCH /api/reg/<id>` | `PATCH api.cloudflareclient.com/v0a1922/reg/<id>` |
| `GET /api/` | health check |

Никаких секретов не хранит — Stateless прокси. Ключи WARP генерируются на
роутере и проходят транзитом.
