import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'

const rootElement = document.getElementById('splify-root')
if (rootElement) {
  // Sync dark mode with OpenWrt/Argon by analyzing actual body background color
  const syncTheme = () => {
    try {
      const bgColor = window.getComputedStyle(document.body).backgroundColor;
      // bgColor is usually in format "rgb(r, g, b)"
      const rgb = bgColor.match(/\d+/g);
      if (rgb && rgb.length >= 3) {
        const brightness = (parseInt(rgb[0]) * 299 + parseInt(rgb[1]) * 587 + parseInt(rgb[2]) * 114) / 1000;
        if (brightness < 128) {
          document.documentElement.classList.add('dark');
        } else {
          document.documentElement.classList.remove('dark');
        }
      }
    } catch (e) {
      console.error("Failed to detect theme", e);
    }
  };
  syncTheme();
  
  // Also observe attributes just in case
  const observer = new MutationObserver(syncTheme);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'class', 'style', 'data-darkmode'] });
  observer.observe(document.body, { attributes: true, attributeFilter: ['data-theme', 'class', 'style'] });

  createRoot(rootElement).render(
    <StrictMode>
      <App />
    </StrictMode>,
  )
} else {
  console.error("splify-root not found!")
}
