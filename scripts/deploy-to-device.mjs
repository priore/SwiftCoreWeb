#!/usr/bin/env node
// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//
// Mode B dev-deploy pusher (spec the frontend development workflows): zips the Vue `dist/` build and PUTs
// it to `PUT /__dev/deploy` on the device, authenticated with the random
// token `app.useDevDeploy(...)` prints to the Xcode console on launch.
// Compiled out of release builds entirely (`#if DEBUG`) on the server side,
// so this script is a DEBUG-only development convenience, never a
// production deployment path.
//
// JavaScript only, no TypeScript, per the project's frontend tooling
// constraint. No dependencies beyond Node's built-ins.
//
// Usage:
//   node scripts/deploy-to-device.mjs --host my-iphone.local --token <token-from-console> [--dist ./dist] [--port 8080]
//
// Typical watch-and-deploy loop during development:
//   vite build --watch &
//   chokidar "dist/**" -c "node scripts/deploy-to-device.mjs --host my-iphone.local --token $TOKEN"
//
// (Or wire it into package.json as a "deploy" script and re-run it manually
// after each `vite build`.)

import { createReadStream, statSync } from 'node:fs'
import { readdir } from 'node:fs/promises'
import path from 'node:path'
import http from 'node:http'
import { spawn } from 'node:child_process'
import { tmpdir } from 'node:os'
import { randomUUID } from 'node:crypto'

function parseArgs(argv) {
  const args = { dist: './dist', port: '8080' }
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--host') args.host = argv[++i]
    else if (arg === '--token') args.token = argv[++i]
    else if (arg === '--dist') args.dist = argv[++i]
    else if (arg === '--port') args.port = argv[++i]
  }
  return args
}

function fail(message) {
  console.error(`deploy-to-device: ${message}`)
  process.exit(1)
}

/**
 * Zips `distDir` into a temporary file using the system `zip` binary
 * (present on macOS by default), matching what `useDevDeploy`'s server-side
 * unpacker expects for a non-multipart payload.
 */
async function zipDist(distDir) {
  const entries = await readdir(distDir)
  if (entries.length === 0) {
    fail(`'${distDir}' is empty — run your production build first (e.g. 'npm run build').`)
  }
  const zipPath = path.join(tmpdir(), `swiftcoreweb-deploy-${randomUUID()}.zip`)
  await new Promise((resolve, reject) => {
    const zip = spawn('zip', ['-r', '-q', zipPath, '.'], { cwd: distDir })
    zip.on('error', reject)
    zip.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`zip exited with code ${code}`))))
  })
  return zipPath
}

function putZip(zipPath, host, port, token) {
  return new Promise((resolve, reject) => {
    const size = statSync(zipPath).size
    const request = http.request(
      {
        host,
        port,
        path: '/__dev/deploy',
        method: 'PUT',
        headers: {
          'Content-Type': 'application/zip',
          'Content-Length': size,
          'X-Dev-Token': token
        }
      },
      (response) => {
        let body = ''
        response.on('data', (chunk) => { body += chunk })
        response.on('end', () => {
          if (response.statusCode && response.statusCode >= 200 && response.statusCode < 300) {
            resolve()
          } else {
            reject(new Error(`Server responded ${response.statusCode}: ${body}`))
          }
        })
      }
    )
    request.on('error', reject)
    createReadStream(zipPath).pipe(request)
  })
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (!args.host) fail('missing --host <device-hostname-or-ip>')
  if (!args.token) fail('missing --token <token-from-Xcode-console>')

  const distDir = path.resolve(process.cwd(), args.dist)
  console.log(`deploy-to-device: zipping '${distDir}'…`)
  const zipPath = await zipDist(distDir)

  console.log(`deploy-to-device: pushing to http://${args.host}:${args.port}/__dev/deploy…`)
  await putZip(zipPath, args.host, args.port, args.token)
  console.log('deploy-to-device: done — the device will reload connected clients via /__dev/livereload.')
}

main().catch((error) => fail(error.message))
