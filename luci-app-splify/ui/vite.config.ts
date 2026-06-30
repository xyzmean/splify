import path from "path"
import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  build: {
    rollupOptions: {
      // Two independent SPA bundles, one per LuCI view: "Главная" (status
      // dashboard) and "Дополнительно" (settings, formerly a form.Map page).
      input: {
        index: path.resolve(__dirname, "index.html"),
        settings: path.resolve(__dirname, "settings.html"),
      },
      output: {
        entryFileNames: `splify-[name].js`,
        chunkFileNames: `splify-[name].js`,
        assetFileNames: (info) =>
          info.name?.endsWith('.css') ? 'splify-index.[ext]' : 'splify-[name].[ext]',
      }
    }
  }
})
