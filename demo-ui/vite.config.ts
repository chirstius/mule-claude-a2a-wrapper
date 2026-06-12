import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import vuetify from 'vite-plugin-vuetify'

// Standard multi-asset build -> dist/. Vuetify is tree-shaken via vite-plugin-vuetify
// (only used components are bundled). The wrapper serves dist/ via http:load-static-resource
// at the app root, so base is '/'. In dev, /a2a is proxied to the local wrapper (no CORS).
export default defineConfig({
  plugins: [vue(), vuetify({ autoImport: true })],
  base: '/',
  build: { outDir: 'dist', emptyOutDir: true },
  server: {
    port: 5173,
    proxy: {
      '/a2a': { target: 'http://localhost:8081', changeOrigin: true },
    },
  },
})
