import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'
import os from 'os'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  cacheDir: path.join(os.tmpdir(), 'vite-et-react'),
  server: {
    host: true,   // bind to 0.0.0.0 so LAN teammates can reach the dev server
    port: 5174,   // fixed port — prevents redirect URLs breaking on every restart
  },
})
