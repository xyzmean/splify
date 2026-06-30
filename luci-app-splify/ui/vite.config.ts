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
      output: {
        entryFileNames: `splify-[name].js`,
        chunkFileNames: `splify-[name].js`,
        assetFileNames: `splify-[name].[ext]`
      }
    }
  }
})
