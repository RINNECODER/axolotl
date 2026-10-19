// Axolotl start page wallpapers. Each preset is a small layer stack of components from the
// MIT `shaders` library (see LICENSE-shaders.txt), rendered with WebGPU. Axolotl drives this
// page from Swift through window.axolotlWallpaper; nothing here touches the network.
import { createShader, isWebGPUSupported } from './shaders.js'

const grain = (strength) => ({ type: 'FilmGrain', props: { strength, bias: 2, animated: false } })
const vignette = (intensity = 0.6, radius = 0.75) =>
  ({ type: 'Vignette', props: { color: '#000000', intensity, radius, falloff: 0.9 } })
const solid = (color) => ({ type: 'SolidColor', props: { color } })

// c = { bg, a, b, accent }, s = speed factor (1 = normal).
const PRESETS = {
  polarVeil: (c, s) => [
    solid(c.bg),
    { type: 'Aurora', props: { colorA: c.a, colorB: c.accent, colorC: c.b, colorSpace: 'oklab', balance: 55,
      intensity: 85, curtainCount: 3, speed: 2.5 * s, waviness: 60, rayDensity: 25, height: 130,
      center: { x: 0.5, y: 0 } } },
    vignette(0.55),
  ],
  inkBloom: (c, s) => [
    { type: 'FlowingGradient', props: { colorA: c.bg, colorB: c.a, colorC: c.bg, colorD: c.b,
      colorSpace: 'oklch', speed: 0.45 * s, distortion: 0.8 } },
    vignette(0.6),
  ],
  velvetMesh: (c, s) => [
    { type: 'MeshGradient', props: { colorSpace: 'oklab', count: 5, smoothness: 3, variation: 0.4,
      swirl: 0.25, drift: 0.5, speed: 0.35 * s,
      stops: [{ color: c.bg, position: 0 }, { color: c.bg, position: 0.3 }, { color: c.a, position: 0.65 },
        { color: c.b, position: 0.9 }, { color: c.accent, position: 1 }] } },
    { type: 'SimplexNoise', props: { colorA: '#ffffff', colorB: '#000000', scale: 3, speed: 0.3 * s },
      opacity: 0.08, blendMode: 'softLight' },
    vignette(0.65),
  ],
  nightDrift: (c, s) => [
    { type: 'LinearGradient', props: { colorA: c.a, colorB: c.bg, start: { x: 0.5, y: 1 }, end: { x: 0.5, y: 0.25 },
      colorSpace: 'oklab' } },
    { type: 'FloatingParticles', props: { particleColor: '#ffffff', shape: 'glow', count: 700, particleSize: 0.8,
      softness: 0.4, speed: 0.03 * s, angle: 200, speedVariance: 0.6, angleVariance: 20, randomness: 0.7,
      twinkle: 0.9, cursorStrength: 0 } },
    { type: 'FloatingParticles', props: { particleColor: c.accent, shape: 'glow', count: 90, particleSize: 1.5,
      softness: 0.6, speed: 0.05 * s, angle: 200, speedVariance: 0.5, angleVariance: 30, randomness: 0.8,
      twinkle: 0.7, cursorStrength: 0 }, opacity: 0.8 },
    vignette(0.5, 0.8),
  ],
  moonlitHaze: (c, s) => [
    solid(c.bg),
    { type: 'RadialGradient', props: { colorA: c.accent, colorB: c.bg, center: { x: 0.74, y: 0.18 }, radius: 0.75,
      colorSpace: 'oklab' }, opacity: 0.35 },
    { type: 'Fog', props: { colorA: c.b, colorB: c.bg, speed: 0.35 * s, turbulence: 0.8, detail: 15, blending: 0.35,
      mouseInfluence: 0, colorSpace: 'oklab' }, opacity: 0.6, blendMode: 'screen' },
    vignette(0.55),
  ],
  tidalDither: (c, s) => [
    solid(c.bg),
    { type: 'SineWave', props: { color: c.a, amplitude: 0.12, frequency: 0.7, speed: 0.25 * s, angle: 0,
      position: { x: 0.5, y: 0.62 }, thickness: 0.3, softness: 0.8 } },
    { type: 'SineWave', props: { color: c.b, amplitude: 0.09, frequency: 1.1, speed: -0.2 * s, angle: 0,
      position: { x: 0.5, y: 0.74 }, thickness: 0.22, softness: 0.8 }, opacity: 0.85 },
    { type: 'SineWave', props: { color: c.accent, amplitude: 0.06, frequency: 1.6, speed: 0.3 * s, angle: 0,
      position: { x: 0.5, y: 0.84 }, thickness: 0.12, softness: 0.8 }, opacity: 0.7 },
    { type: 'Dither', props: { pattern: 'bayer4', pixelSize: 2, threshold: 0.5, spread: 1, colorMode: 'source' } },
    vignette(0.5),
  ],
  emberPlasma: (c, s) => [
    { type: 'Plasma', props: { density: 1.4, speed: 0.45 * s, intensity: 1.6, warp: 0.6, contrast: 1.4, balance: 45,
      colorA: c.b, colorB: c.bg, colorSpace: 'oklab' } },
    { type: 'RadialGradient', props: { colorA: c.accent, colorB: c.bg, center: { x: 0.8, y: 0.85 }, radius: 0.9,
      colorSpace: 'oklab' }, opacity: 0.18, blendMode: 'screen' },
    vignette(0.7),
  ],
  halftoneDusk: (c, s) => [
    { type: 'MeshGradient', props: { colorSpace: 'oklab', count: 4, smoothness: 3, variation: 0.3, swirl: 0.2,
      drift: 0.4, speed: 0.3 * s,
      stops: [{ color: c.bg, position: 0 }, { color: c.a, position: 0.45 }, { color: c.b, position: 0.8 },
        { color: c.accent, position: 1 }] } },
    { type: 'Halftone', props: { style: 'classic', frequency: 80, angle: 30, paperColor: '#ffffff', blackColor: '#000000' },
      opacity: 0.55, blendMode: 'multiply' },
    vignette(0.6),
  ],
  marbleSmoke: (c, s) => [
    { type: 'Marble', props: { colorA: c.a, colorB: c.bg, colorC: c.bg, scale: 1.5, turbulence: 10, speed: 0.025 * s,
      colorSpace: 'oklab' } },
    { type: 'SolidColor', props: { color: c.accent }, opacity: 0.08, blendMode: 'softLight' },
    vignette(0.65),
  ],
  lunarRays: (c, s) => [
    solid(c.bg),
    { type: 'RadialGradient', props: { colorA: c.a, colorB: c.bg, center: { x: 0.5, y: -0.1 }, radius: 1.1,
      colorSpace: 'oklab' }, opacity: 0.7 },
    { type: 'Godrays', props: { center: { x: 0.5, y: -0.08 }, density: 0.22, intensity: 0.45, spotty: 0.6,
      speed: 0.25 * s, rayColor: c.accent, backgroundColor: 'transparent' }, opacity: 0.8 },
    vignette(0.5),
  ],
}

const canvas = document.getElementById('wall')
const fallback = document.getElementById('fallback')
let shader = null
let applied = null      // JSON of the last config we built
let current = null      // ...and that config
let movers = []         // ids of the layers parallax shifts, back to front
let active = false      // Axolotl says the start page is on screen
let still = false       // Reduce Motion / Low Power: draw once, then hold the frame
let building = Promise.resolve()

const post = (msg) => { try { window.webkit.messageHandlers.axolotlWallpaper.postMessage(msg) } catch { /* not in Axolotl */ } }

function showFallback(cfg) {
  const { bg, a, b, accent } = cfg.colors
  fallback.style.background =
    `radial-gradient(120% 90% at 75% 10%, ${accent}33 0%, transparent 55%),` +
    `radial-gradient(110% 80% at 15% 100%, ${b}55 0%, transparent 60%),` +
    `linear-gradient(180deg, ${bg} 0%, ${a} 140%)`
  fallback.classList.add('shown')
  canvas.classList.remove('ready')
}

// Filters work on the layers below them; zoom and parallax move only the others.
const FILTERS = new Set(['FilmGrain', 'Vignette', 'Dither', 'Halftone', 'CursorRipples'])
const GRAIN_MAX = 0.3   // FilmGrain strength at the Grain slider's 100%
const PARALLAX = 0.04   // how far (in screen widths) the top layer shifts at the window edge

function toPreset(cfg) {
  const make = PRESETS[cfg.preset]
  if (!make) return null
  const layers = make(cfg.colors, cfg.speed)
  const vignette = layers.pop()
  const zoom = cfg.zoom ?? 1
  // A tiny offset keeps the transform live, so parallax moves don't rebuild the pipeline.
  if (zoom !== 1 || cfg.pointer === 'parallax') for (const l of layers) {
    if (!FILTERS.has(l.type)) l.transform = { scale: zoom, edges: 'mirror', offsetX: 1e-4, offsetY: 0 }
  }
  if (cfg.pointer === 'glow') layers.push({ type: 'RadialGradient', props: { colorA: cfg.colors.accent, colorB: '#000000',
    center: { type: 'mouse-position', smoothing: 0.6 }, radius: 0.45, colorSpace: 'oklab' }, opacity: 0.22, blendMode: 'screen' })
  if (cfg.pointer === 'ripple') layers.push({ type: 'CursorRipples', props: { intensity: 5, decay: 6, radius: 0.4, chromaticSplit: 0.6 } })
  if (cfg.grain > 0) layers.push(grain(cfg.grain * GRAIN_MAX))
  layers.push(vignette)
  // opacity, blendMode and transform are universal props, so they travel with the others.
  return {
    components: layers.map(({ type, props, opacity, blendMode, transform }, i) => ({
      type, id: `l${i}`, children: [],
      props: { ...props, ...(opacity !== undefined && { opacity }), ...(blendMode && { blendMode }), ...(transform && { transform }) },
    })),
  }
}

// Pointer input from Axolotl, normalized to 0...1 with y down. Axolotl sends it only while
// the start page is on screen, animating, and the preset has an effect turned on.
let wake = null
function pointer(x, y, click) {
  if (!shader || !current) return
  const cfg = current
  const clientX = x * window.innerWidth, clientY = y * window.innerHeight
  if (click) { if (cfg.click === 'burst') burst(clientX, clientY); return }
  if (cfg.pointer === 'glow' || cfg.pointer === 'ripple') {
    window.dispatchEvent(new MouseEvent('mousemove', { clientX, clientY }))
  } else if (cfg.pointer === 'parallax') {
    movers.forEach((id, i) => {
      const depth = PARALLAX * (i + 1) / movers.length
      shader.update(id, { transform: { offsetX: (0.5 - x) * depth + 1e-4, offsetY: (y - 0.5) * depth } })
    })
  }
  // A frozen (speed 0) wallpaper wakes for a moment so the effect can draw, then holds again.
  if (still && active) {
    shader.resume()
    clearTimeout(wake)
    wake = setTimeout(syncRunning, 600)
  }
}

// Click: a soft ring of accent light that grows and fades, drawn by the compositor.
function burst(x, y) {
  const el = document.createElement('div')
  el.className = 'burst'
  el.style.left = `${x}px`; el.style.top = `${y}px`
  el.style.setProperty('--accent', current.colors.accent)
  el.addEventListener('animationend', () => el.remove())
  document.body.appendChild(el)
}

function syncRunning() {
  if (!shader) return
  if (active && !still) shader.resume()
  else shader.pause()
}

async function build(cfg) {
  document.documentElement.style.setProperty('--intensity', String(cfg.intensity))
  const preset = toPreset(cfg)
  if (shader) { shader.destroy(); shader = null }
  canvas.classList.remove('ready')
  movers = preset ? preset.components.filter((c) => c.props.transform).map((c) => c.id) : []
  if (!preset) { fallback.classList.remove('shown'); post({ state: 'none' }); return }
  if (!isWebGPUSupported() || !navigator.gpu) { showFallback(cfg); post({ state: 'fallback', reason: 'unsupported' }); return }
  try {
    const instance = await createShader(canvas, preset, {
      disableTelemetry: true,
      observeElement: false,
      colorSpace: 'srgb',
      onError: (reason) => {
        if (instance && instance.getFailureReason && instance.getFailureReason()) {
          showFallback(cfg); post({ state: 'fallback', reason })
        }
      },
    })
    shader = instance
    const renderer = instance.axolotlRenderer && instance.axolotlRenderer()
    if (renderer) {
      renderer.setFrameRateCap(cfg.fps)
      renderer.setResolutionScale(cfg.scale)
    }
    if (instance.getFailureReason()) { showFallback(cfg); post({ state: 'fallback', reason: instance.getFailureReason() }); return }
    fallback.classList.remove('shown')
    canvas.classList.add('ready')
    // Hold a still frame a moment after start so the first frames have drawn.
    if (!active || still) setTimeout(syncRunning, 250)
    else syncRunning()
    post({ state: 'running', preset: cfg.preset })
  } catch (e) {
    showFallback(cfg); post({ state: 'fallback', reason: String(e && e.message || e) })
  }
}

window.axolotlWallpaper = {
  apply(cfg) {
    still = !!cfg.still || cfg.speed === 0
    const key = JSON.stringify({ ...cfg, still: undefined, intensity: undefined })
    document.documentElement.style.setProperty('--intensity', String(cfg.intensity))
    if (key === applied) { syncRunning(); return }
    applied = key
    current = cfg
    building = building.then(() => build(cfg))
  },
  setActive(on) {
    active = !!on
    building.then(syncRunning)
  },
  pointer,
  // A still JPEG of a preset for the settings picker; runs one at a time.
  snapshot(cfg, w, h) {
    const job = building.then(() => snapshot(cfg, w, h))
    building = job.catch(() => {})
    return job
  },
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms))
const nextFrame = () => new Promise((r) => requestAnimationFrame(() => r()))

function fallbackImage(cfg, w, h) {
  const c = document.createElement('canvas')
  c.width = w * 2; c.height = h * 2
  const g = c.getContext('2d')
  const lin = g.createLinearGradient(0, 0, 0, c.height)
  lin.addColorStop(0, cfg.colors.bg); lin.addColorStop(1, cfg.colors.a)
  g.fillStyle = lin; g.fillRect(0, 0, c.width, c.height)
  return c.toDataURL('image/jpeg', 0.85)
}

async function snapshot(cfg, w, h) {
  const preset = toPreset(cfg)
  if (!preset || !isWebGPUSupported() || !navigator.gpu) return fallbackImage(cfg, w, h)
  const c = document.createElement('canvas')
  c.style.cssText = `position:fixed;left:0;top:0;width:${w}px;height:${h}px;opacity:1`
  document.body.appendChild(c)
  let instance = null
  try {
    instance = await createShader(c, preset, { disableTelemetry: true, observeElement: false, colorSpace: 'srgb' })
    if (instance.getFailureReason()) return fallbackImage(cfg, w, h)
    await wait(350)
    await nextFrame()
    return c.toDataURL('image/jpeg', 0.85)
  } catch {
    return fallbackImage(cfg, w, h)
  } finally {
    if (instance) instance.destroy()
    c.remove()
  }
}
// We size and pause the canvas ourselves (observeElement: false) so the library's own
// visibility observer can't restart a wallpaper Axolotl has paused.
let resizeTimer = null
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer)
  resizeTimer = setTimeout(() => { if (shader) shader.resize(window.innerWidth, window.innerHeight) }, 60)
})
post({ state: 'loaded' })
