// Shared toast helper (was copy-pasted verbatim into 4 components). Prefers
// LuCI's own notification area; if `window.ui` isn't present (view failed to
// load `ui.js`, or we're mounted somewhere unusual) an action would otherwise
// fail completely silently, so fall back to a minimal in-DOM toast instead of
// just console.log — a router admin needs SOME visible confirmation.
export type NotifyKind = 'info' | 'warning' | 'error'

const KIND_BG: Record<NotifyKind, string> = {
  info: '#334155',
  warning: '#d97706',
  error: '#dc2626',
}

function fallbackToast(msg: string, kind: NotifyKind) {
  if (typeof document === 'undefined') return
  const el = document.createElement('div')
  el.textContent = msg
  Object.assign(el.style, {
    position: 'fixed', left: '50%', bottom: '16px', transform: 'translateX(-50%)',
    zIndex: '2147483647', maxWidth: '90vw', padding: '8px 14px', borderRadius: '8px',
    font: '13px/1.4 system-ui, sans-serif', color: '#fff',
    boxShadow: '0 2px 8px rgba(0,0,0,.25)', background: KIND_BG[kind],
  } satisfies Partial<CSSStyleDeclaration>)
  document.body.appendChild(el)
  setTimeout(() => el.remove(), 4000)
}

export function notify(msg: string, kind: NotifyKind = 'info') {
  try {
    if (window.ui?.addNotification) {
      window.ui.addNotification(null, window.L ? window.L.dom.create('p', {}, msg) : msg, kind)
      return
    }
  } catch { /* fall through to the in-app toast */ }
  fallbackToast(msg, kind)
}
