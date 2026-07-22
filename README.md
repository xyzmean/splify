# splify

**splify** превращает роутер с OpenWrt в умный VPN-шлюз: заблокированные сайты
идут через VPN, всё остальное — напрямую и на полной скорости. Настройка — одна
команда и пара кнопок.

## Установка одной командой

На роутере (OpenWrt 24.10+/25.12+) выполните:

    wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/install.sh | sh

## Автонастройка с WARP «из коробки» (easyinstall)

Хотите сразу рабочий туннель без ручного создания интерфейса? `easyinstall.sh`
делает всё то же, что `install.sh`, **плюс**:

- регистрирует анонимное устройство Cloudflare WARP,
- поднимает туннель `warp0` как AmneziaWG с встроенной обфускацией против DPI
  (Jc/Jmin/Jmax/H1–H4/I1/S1/S2) — именно обфускация позволяет туннелю пройти
  там, где обычный WireGuard блокируется по сигнатурам,
- регистрирует `warp0` первым endpoint'ом splify и включает маршрутизацию.

### Если Cloudflare API заблокирован вашим провайдером

Регистрация идёт через `api.cloudflareclient.com`, который некоторые ISP
блокируют. В этом случае поднимите Vercel-прокси (1 минута) и передайте его URL
через `WORKER_URL`:

1. [vercel.com](https://vercel.com) → **Add New… → Project** (Import Git или
   Create Blank). Положите в корень файлы из
   [`contrib/warp-api-proxy-vercel/`](contrib/warp-api-proxy-vercel)
   (`api/[...path].js` и `package.json`).
2. **Deploy**. Скопируйте URL вида `https://<app>.vercel.app`.
   Проверьте: `curl https://<app>.vercel.app/api/` → `warp-api-proxy (vercel) ok`.
3. Запустите установку:

       wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/easyinstall.sh \
         | WORKER_URL="https://<app>.vercel.app" sh

> Почему Vercel, а не CF Worker? Worker на `*.workers.dev` упирается в
> Cloudflare error 1015 (rate-limit на shared egress IP), а Vercel ходит в
> интернет с AWS-диапазонов и лимита не ловит. CF Worker-вариант тоже есть —
> [`contrib/warp-api-proxy.worker.js`](contrib/warp-api-proxy.worker.js) — но он
> работает только там, где Cloudflare не применяет rate-limit.

Если API не заблокирован — `WORKER_URL` не нужен, `easyinstall.sh` обратится к
Cloudflare напрямую.

Логику регистрации (формат запроса wgcf) позаимствовали у
[wgcf](https://github.com/ViRb3/wgcf). Зависимости `curl` и `jq` ставятся
автоматически, если их нет.

## Если нужна помощь)
    https://t.me/+R94Mex2A_7JlNGYy

## Быстрый старт

1. Создайте VPN-туннель: **Сеть → Интерфейсы** (WireGuard или AmneziaWG).
2. Откройте **Сервисы → splify → Главная**, выберите туннель и нажмите **«Включить»**.

Готово. Подробнее — в [документации](docs/ru/Home.md).

## Что умеет

- Простой режим: одна кнопка вкл/выкл и выбор туннеля.
- Автоматические списки заблокированного — обновляются сами.
- Резервные туннели с переключением при сбое.
- Обход блокировок по DPI (zapret), если он установлен.
- Всё тонкое — под вкладкой **«Дополнительно»**.
- Заложен фундамент под **sing-box** (см. [docs/ru/sing-box.md](docs/ru/sing-box.md)).

## Удаление

    wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/uninstall.sh | sh
