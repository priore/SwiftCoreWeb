// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//
// Ready-to-copy Vite config for Mode A (spec the frontend development workflows): Vue runs on the Mac with
// full HMR, and every /api/* call is proxied to SwiftCoreWeb running on the
// iOS device. JavaScript only — no TypeScript, per the project's frontend
// tooling constraint.
//
// Usage:
//   1. Copy this file to your Vue project's root as vite.config.js.
//   2. Replace DEVICE_HOSTNAME below with your device's Bonjour name
//      (Settings > General > About > Name, lowercased, with '.local'), or
//      its LAN IP address. The server must be running with
//      `builder.listenOnAllInterfaces()` and, optionally, `builder.advertise(name:)`.
//   3. `npm run dev` — the Vue app opens on the Mac, and every request to
//      /api/* is transparently proxied to the device over the LAN.

import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

const DEVICE_HOSTNAME = 'my-iphone.local'
const DEVICE_PORT = 8080

export default defineConfig({
  plugins: [vue()],
  server: {
    host: true,
    port: 5173,
    proxy: {
      '/api': {
        target: `http://${DEVICE_HOSTNAME}:${DEVICE_PORT}`,
        changeOrigin: true
      },
      '/openapi.json': {
        target: `http://${DEVICE_HOSTNAME}:${DEVICE_PORT}`,
        changeOrigin: true
      },
      '/ws': {
        target: `ws://${DEVICE_HOSTNAME}:${DEVICE_PORT}`,
        ws: true
      }
    }
  },
  build: {
    outDir: 'dist',
    // Hashed asset filenames match the immutable Cache-Control policy
    // `useStaticFiles`/`useSpa` apply to `/assets/*-[hash].*` (spec the static file hosting design).
    assetsDir: 'assets'
  }
})
