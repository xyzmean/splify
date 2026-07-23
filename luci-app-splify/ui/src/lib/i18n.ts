// Лёгкая gettext-подобная обёртка без зависимостей.
//
// Зачем: раньше все русские строки были захардкожены прямо в .tsx. Это
// работало (русский — единственный целевой язык), но отсутствовал единый
// каталог: поменять формулировку означало найти её по всем компонентам, а
// po/ru/splify.po (для классической LuCI-view части) жил своей жизнью и
// быстро рассинхронизировался с React-интерфейсом.
//
// Теперь ключ = читаемый msgid (как в .po), значение = ru-перевод. Каталог
// здесь — единственный источник правды для React-стороны; po/ru/splify.po
// держим синхронно вручную (он относится к LuCI-view). t() для неизвестного
// msgid возвращает его как есть — безопасный фолбэк, чтобы пропуск строки
// через t() никогда не ломал интерфейс.
//
// Полный перенос существующих строк делается постепенно: оборачиваются новые и
// изменяемые строки плюс ключевые видимые термины. Необработанные русские
// строки в .tsx продолжают работать — t('русская строка') просто вернёт её же.

const RU: Record<string, string> = {
  // ── App.tsx (навигация) ──────────────────────────────────────────────
  'Status': 'Состояние',
  'AmneziaWG': 'AmneziaWG',
  'Remote control': 'Удалённое управление',
  'Loading splify…': 'Загрузка splify…',
  'Error:': 'Ошибка:',

  // ── StatusDashboard: hero ────────────────────────────────────────────
  'Mode': 'Режим',
  'Kill switch': 'Kill switch',
  'on': 'вкл',
  'off': 'выкл',
  'Tunnel': 'Туннель',
  'handshake': 'handshake',
  'RX': 'Приём',
  'TX': 'Передача',
  'Failures': 'Сбоев',
  'Lists OK': 'Списки OK',
  'Enable': 'Включить',
  'Disable': 'Выключить',
  'Turn on split routing?': 'Включить split-маршрутизацию?',
  'Turn off split routing? All LAN traffic will go via WAN until the service re-enables it.':
    'Выключить split-маршрутизацию? Весь трафик LAN пойдёт через WAN, пока служба не включится снова.',
  'Split routing enabled': 'Split-маршрутизация включена',
  'Split routing disabled': 'Split-маршрутизация выключена',

  // ── toolbar ──────────────────────────────────────────────────────────
  'Refresh': 'Обновить',
  'Apply': 'Применить',
  'Apply the splify configuration now': 'Применить конфигурацию splify сейчас',
  'Restart': 'Перезапустить',
  'Restart the splify service': 'Перезапустить службу splify',
  'Lists': 'Списки',
  'Update the ipsum (blocked IP) list': 'Обновить список ipsum (заблокированные IP)',
  'Update the ru/cn (direct) list': 'Обновить список ru/cn (напрямую)',
  'Update the VPN domains list': 'Обновить список VPN-доменов',
  'Configuration applied': 'Конфигурация применена',
  'Service restarted': 'Служба перезапущена',
  'ipsum updated': 'ipsum обновлён',
  'ru/cn updated': 'ru/cn обновлён',
  'domains updated': 'домены обновлены',
  'Emergency disable': 'Аварийно отключить',
  'Disable split routing now? All LAN traffic will exit via WAN until the service re-enables it (or you stop it).':
    'Отключить split-маршрутизацию сейчас? Весь трафик LAN выйдет через WAN, пока служба не включит её снова.',

  // ── first-run ────────────────────────────────────────────────────────
  "Let's connect the first tunnel": 'Подключим первый туннель',
  'No tunnels yet, so all LAN traffic currently goes through plain WAN.':
    'Туннелей пока нет, поэтому весь трафик LAN сейчас идёт через обычный WAN.',

  // ── Путь трафика (классы трафика) ────────────────────────────────────
  'Traffic path': 'Путь трафика',
  'Internet': 'Интернет',
  'Blocked sites': 'Заблокированные сайты',
  'RU / neutral': 'Российский / нейтральный',
  'Other traffic': 'Прочий трафик',
  'via VPN': 'через VPN',
  'via WAN': 'через WAN',
  'Direct (WAN)': 'напрямую (WAN)',
  'Open (WAN)': 'открыто (WAN)',
  'DPI bypass (zapret)': 'обход DPI (zapret)',
  'Blocked — kill switch': 'заблокировано — kill switch',
  'none': 'нет',

  // ── Туннели ──────────────────────────────────────────────────────────
  'Tunnels (failover)': 'Туннели (failover)',
  'online': 'онлайн',
  'Prio': 'Прио',
  'Handshake': 'Handshake',
  'Traffic': 'Трафик',
  'Health': 'Health',
  'Zone': 'Зона',
  'Masq': 'Masq',
  'Masquerade (masq) hides LAN behind the tunnel IP': 'Masquerade (masq) прячет LAN за IP-адресом туннеля',
  'LAN fwd': 'LAN-fwd',
  'Forwarding lan → tunnel is required for traffic to reach the tunnel':
    'Форвардинг lan → туннель нужен, чтобы трафик дошёл до туннеля',

  // ── диагностика / события ────────────────────────────────────────────
  'Diagnostics': 'Диагностика',
  'No problems detected.': 'Проблем не обнаружено.',
  'Fix': 'Исправить',
  'Create/repair the firewall zone for “%s” (accept-all + masquerading + lan↔tunnel↔wan forwarding) and reload the firewall?':
    'Создать/починить firewall-зону для «%s» (accept-all + masquerade + форвардинг lan↔туннель↔wan) и перезагрузить firewall?',
  'Firewall fixed for %s': 'Firewall починен для %s',
  'Could not fix firewall for %s': 'Не удалось починить firewall для %s',
  'Firewall fix error:': 'Ошибка firewall-fix:',
  'Event history': 'История событий',
  'No failover events recorded yet.': 'Событий переключения пока не зафиксировано.',

  // ── термины-подсказки ────────────────────────────────────────────────
  'DPI bypass hint': 'обход блокировок провайдера на уровне пакетов (DPI)',
  'Kill switch hint': 'сбрасывать трафик вместо утечки в WAN, когда все туннели упали',
  'Failover hint': 'автопереключение на резервный туннель при сбое',

  // ── WgPanel ──────────────────────────────────────────────────────────
  'AmneziaWG / WireGuard settings': 'Параметры AmneziaWG / WireGuard',
  'key set': 'ключ задан',
  'no key': 'без ключа',
  'Save and reconnect': 'Сохранить и переподключить',
  'Saving…': 'Сохраняю…',
  'Endpoint (server)': 'Endpoint (сервер)',
  'port': 'порт',
  'AllowedIPs (comma-separated)': 'AllowedIPs (через запятую)',
  'Interface addresses': 'Адреса интерфейса',
  'Public key of the peer': 'Public key пира',
  'Persistent keepalive': 'Persistent keepalive',
  'AmneziaWG obfuscation — counters': 'Обфускация AmneziaWG — счётчики',
  'Junk packets (AWG 1.5): I1–I5, J1–J3': 'Junk-пакеты (AWG 1.5): I1–I5, J1–J3',
  'collapse ▲': 'свернуть ▲',
  'expand ▼': 'развернуть ▼',
  'Private key of the interface': 'Приватный ключ интерфейса',
  'Show': 'Показать',
  'Leave empty to keep the current key.': 'Оставьте поле пустым, чтобы не менять текущий ключ.',
  'Import .conf (AmneziaWG / WireGuard)': 'Импорт .conf (AmneziaWG / WireGuard)',
  'Import and reconnect': 'Импортировать и переподключить',
  'Importing…': 'Импортирую…',

  // ── ApiPanel ─────────────────────────────────────────────────────────
  'Connected': 'Подключено',
  'Agent': 'Агент',
  'running': 'работает',
  'starting': 'запускается',
  'Last poll': 'Последний опрос',
  'Node name': 'Имя ноды',
  'Save name': 'Сохранить имя',
  'Connect to the control panel': 'Подключить к панели',
  'Connect': 'Подключить',
  'Connecting…': 'Подключаю…',
  'Re-register': 'Перерегистрировать',
  'Outbound agent (CGNAT / down tunnel)': 'Исходящий агент (CGNAT / упавший туннель)',
  'Save addresses': 'Сохранить адреса',
  'Inbound REST API (LAN / WG)': 'Входящий REST API (LAN / WG)',
  'Change': 'Сменить',
  'Retry': 'Повторить',

  // ── SettingsPage ─────────────────────────────────────────────────────
  'Delete': 'Удалить',
  'Add': 'Добавить',
}

/**
 * Перевести msgid на русский. Неизвестный msgid возвращается как есть —
 * поэтому t('уже русская строка') безопасно вернёт её же (для ещё не
 * перенесённых строк), а t('english') без записи в словаре покажет английский.
 */
export function t(msgid: string): string {
  return RU[msgid] ?? msgid
}
