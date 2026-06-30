import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import SettingsPage from './components/SettingsPage.tsx'

// Same re-mount guard as main.tsx (see comment there) — LuCI re-injects this
// module every time the operator navigates back to the "Дополнительно" view.
declare global {
  interface Window { __splifySettingsRoot?: import('react-dom/client').Root; __splifySettingsObserver?: MutationObserver }
}
if (window.__splifySettingsRoot) { try { window.__splifySettingsRoot.unmount() } catch { /* */ } window.__splifySettingsRoot = undefined }
if (window.__splifySettingsObserver) { try { window.__splifySettingsObserver.disconnect() } catch { /* */ } window.__splifySettingsObserver = undefined }

const rootElement = document.getElementById('splify-root')
if (rootElement) {
  // Sync dark mode with OpenWrt/Argon the same way the dashboard bundle does.
  const syncTheme = () => {
    try {
      const bgColor = window.getComputedStyle(document.body).backgroundColor
      const rgb = bgColor.match(/\d+/g)
      if (rgb && rgb.length >= 3) {
        const brightness = (parseInt(rgb[0]) * 299 + parseInt(rgb[1]) * 587 + parseInt(rgb[2]) * 114) / 1000
        if (brightness < 128) document.documentElement.classList.add('dark')
        else document.documentElement.classList.remove('dark')
      }
    } catch (e) {
      console.error('Failed to detect theme', e)
    }
  }
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
} else {
  console.error('splify-root not found!')
}
