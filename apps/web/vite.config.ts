import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Production builds are served from GitHub Pages at
// https://studio-node.github.io/filmCage/, so assets need that prefix.
// Local dev (npm run dev) stays at the site root.
export default defineConfig(({ command }) => ({
  base: command === 'build' ? '/filmCage/' : '/',
  plugins: [vue()],
  server: {
    port: 5173,
  },
}))
