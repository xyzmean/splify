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

- регистрирует анонимное устройство Cloudflare WARP (через `api.cloudflareclient.com`),
- поднимает туннель `warp0` как AmneziaWG с встроенной обфускацией против DPI
  (Jc/Jmin/Jmax/H1–H4/I1/S1/S2),
- регистрирует `warp0` первым endpoint'ом splify и включает маршрутизацию.

    wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/easyinstall.sh | sh

Требуются `curl` и `jq` (`apk add curl jq`, если их нет). Логику регистрации
WARP позаимствовали у [warp-config-generator-vercel](https://github.com/nellimonix/warp-config-generator-vercel).

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
