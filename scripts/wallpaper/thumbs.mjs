// Renders the settings picker thumbnails (Assets.xcassets/WallpaperThumbs) from the bundled
// WallpaperWeb page in headless Chromium (WebGPU), one per preset in its default style.
//
//   cd scripts/wallpaper && npm install --no-save playwright-core@1.62.0 && npx playwright-core install chromium && node thumbs.mjs
//
// Rerun after changing a preset in wallpaper.js or a default style in WallpaperModel.swift.
import { chromium } from 'playwright-core'
import { fileURLToPath } from 'node:url'
import http from 'node:http'
import path from 'node:path'
import fs from 'node:fs'

const here = path.dirname(fileURLToPath(import.meta.url))
const web = path.resolve(here, '../../Axolotl/Wallpaper/WallpaperWeb')
const out = path.resolve(here, '../../Axolotl/Assets.xcassets/WallpaperThumbs')
const model = fs.readFileSync(path.resolve(here, '../../Axolotl/Wallpaper/WallpaperModel.swift'), 'utf8')

// The Swift model is the source of truth for palettes, accents and default styles.
const palettes = Object.fromEntries([...model.matchAll(/id: "(\w+)", name: "[^"]*", base: "(#\w+)", mid: "(#\w+)", high: "(#\w+)"/g)]
  .map(([, id, bg, a, b]) => [id, { bg, a, b }]))
const accents = Object.fromEntries([...model.matchAll(/id: "(\w+)", name: "[^"]*", hex: "(#\w+)"/g)].map(([, id, hex]) => [id, hex]))
const styles = {}
for (const [, cases, palette, accent, grain] of model.matchAll(/case ([.\w, ]+): return WallpaperStyle\(palette: "(\w+)", accent: "(\w+)"(?:, grain: ([\d.]+))?\)/g))
  for (const c of cases.split(',')) styles[c.trim().slice(1)] = { palette, accent, grain: Number(grain ?? 0) }
delete styles.none

const types = { html: 'text/html', js: 'text/javascript' }
const server = http.createServer((req, res) => {
  const file = path.join(web, path.basename(req.url))
  if (!fs.existsSync(file)) { res.writeHead(404).end(); return }
  res.writeHead(200, { 'Content-Type': types[path.extname(file).slice(1)] || 'application/octet-stream' }).end(fs.readFileSync(file))
}).listen(0, '127.0.0.1')
await new Promise((r) => server.once('listening', r))

const browser = await chromium.launch({ args: ['--enable-unsafe-webgpu', '--ignore-gpu-blocklist', '--enable-gpu', '--use-angle=metal'] })
fs.mkdirSync(out, { recursive: true })
fs.writeFileSync(path.join(out, 'Contents.json'), JSON.stringify({ info: { author: 'xcode', version: 1 } }, null, 2) + '\n')
for (const [preset, { palette, accent, grain }] of Object.entries(styles)) {
  const page = await browser.newPage({ viewport: { width: 132, height: 66 }, deviceScaleFactor: 2 })
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`)
  await page.evaluate((cfg) => {
    window.webkit = { messageHandlers: { axolotlWallpaper: { postMessage: (m) => { window.lastState = m.state } } } }
    window.axolotlWallpaper.apply(cfg)
    window.axolotlWallpaper.setActive(true)
  }, { preset, colors: { ...palettes[palette], accent: accents[accent] }, speed: 1, intensity: 1, grain, fps: 60, scale: 1, still: false })
  await page.waitForTimeout(2000) // let the shader move off its first frame
  // The page falls back to a CSS gradient without WebGPU; never commit that as a thumbnail.
  const state = await page.evaluate(() => window.lastState)
  if (state !== 'running') throw new Error(`${preset}: ${state}`)
  const set = path.join(out, `wallpaper-${preset}.imageset`)
  fs.mkdirSync(set, { recursive: true })
  await page.screenshot({ path: path.join(set, 'thumb@2x.png') })
  fs.writeFileSync(path.join(set, 'Contents.json'), JSON.stringify({
    images: [{ filename: 'thumb@2x.png', idiom: 'universal', scale: '2x' }], info: { author: 'xcode', version: 1 },
  }, null, 2) + '\n')
  console.log(preset)
  await page.close()
}
await browser.close()
server.close()
