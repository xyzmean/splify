import { StrictMode } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import './index.css'
import SettingsPage from './components/SettingsPage.tsx'

// Same single-instance mount contract as main.tsx (see the comment there) — the
// host view (view/splify/settings.js) loads this module once with a stable URL
// and calls window.__splifySettingsMount on every visit instead of re-injecting
// a cache-busted <script>, which would leak a fresh module each navigation.
declare global {
  interface Window {
    __splifySettingsRoot?: Root
    __splifySettingsObserver?: MutationObserver
    __splifySettingsMount?: (el?: HTMLElement | null) => void
  }
}

function teardown() {
  if (window.__splifySettingsRoot) { try { window.__splifySettingsRoot.unmount() } catch { /* */ } window.__splifySettingsRoot = undefined }
  if (window.__splifySettingsObserver) { try { window.__splifySettingsObserver.disconnect() } catch { /* */ } window.__splifySettingsObserver = undefined }
}

function syncTheme() {
  try {
    const bgColor = window.getComputedStyle(document.body).backgroundColor
    const rgb = bgColor.match(/\d+/g)
    if (rgb && rgb.length >= 3) {
      const brightness = (parseInt(rgb[0]) * 299 + parseInt(rgb[1]) * 587 + parseInt(rgb[2]) * 114) / 1000
      document.documentElement.classList.toggle('dark', brightness < 128)
    }
  } catch (e) {
    console.error('Failed to detect theme', e)
  }
}

function mount(el?: HTMLElement | null) {
  const rootElement = el ?? document.getElementById('splify-root')
  if (!rootElement) { console.error('splify-root not found!'); return }
  teardown()

  syncTheme()
  const observer = new MutationObserver(syncTheme)
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'class', 'style', 'data-darkmode'] })
  observer.observe(document.body, { attributes: true, attributeFilter: ['data-theme', 'class', 'style'] })
  window.__splifySettingsObserver = observer

  const root = createRoot(rootElement)
  window.__splifySettingsRoot = root
  root.render(
    <StrictMode>
      <SettingsPage />
    </StrictMode>,
  )
}

window.__splifySettingsMount = mount
mount()
