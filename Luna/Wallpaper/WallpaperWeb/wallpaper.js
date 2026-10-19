// Luna start page wallpapers. Each preset is a small layer stack of components from the
// MIT `shaders` library (see LICENSE-shaders.txt), rendered with WebGPU. Luna drives this
// page from Swift through window.lunaWallpaper; nothing here touches the network.
import { createShader, isWebGPUSupported } from './shaders.js'

const grain = (strength = 0.14) => ({ type: 'FilmGrain', props: { strength, bias: 2, animated: false } })
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
    grain(0.12), vignette(0.55),
  ],
  inkBloom: (c, s) => [
    { type: 'FlowingGradient', props: { colorA: c.bg, colorB: c.a, colorC: c.bg, colorD: c.b,
      colorSpace: 'oklch', speed: 0.45 * s, distortion: 0.8 } },
    grain(0.12), vignette(0.6),
  ],
  velvetMesh: (c, s) => [
    { type: 'MeshGradient', props: { colorSpace: 'oklab', count: 5, smoothness: 3, variation: 0.4,
      swirl: 0.25, drift: 0.5, speed: 0.35 * s,
      stops: [{ color: c.bg, position: 0 }, { color: c.bg, position: 0.3 }, { color: c.a, position: 0.65 },
        { color: c.b, position: 0.9 }, { color: c.accent, position: 1 }] } },
    { type: 'SimplexNoise', props: { colorA: '#ffffff', colorB: '#000000', scale: 3, speed: 0.3 * s },
      opacity: 0.08, blendMode: 'softLight' },
    grain(0.16), vignette(0.65),
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
    grain(0.1), vignette(0.55),
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
    grain(0.12), vignette(0.7),
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
    grain(0.15), vignette(0.65),
  ],
  lunarRays: (c, s) => [
    solid(c.bg),
    { type: 'RadialGradient', props: { colorA: c.a, colorB: c.bg, center: { x: 0.5, y: -0.1 }, radius: 1.1,
      colorSpace: 'oklab' }, opacity: 0.7 },
    { type: 'Godrays', props: { center: { x: 0.5, y: -0.08 }, density: 0.22, intensity: 0.45, spotty: 0.6,
      speed: 0.25 * s, rayColor: c.accent, backgroundColor: 'transparent' }, opacity: 0.8 },
    grain(0.12), vignette(0.5),
  ],
}

const canvas = document.getElementById('wall')
const fallback = document.getElementById('fallback')
let shader = null
let applied = null      // JSON of the last config we built
let active = false      // Luna says the start page is on screen
let still = false       // Reduce Motion / Low Power: draw once, then hold the frame
let building = Promise.resolve()

const post = (msg) => { try { window.webkit.messageHandlers.lunaWallpaper.postMessage(msg) } catch { /* not in Luna */ } }

function showFallback(cfg) {
  const { bg, a, b, accent } = cfg.colors
  fallback.style.background =
    `radial-gradient(120% 90% at 75% 10%, ${accent}33 0%, transparent 55%),` +
    `radial-gradient(110% 80% at 15% 100%, ${b}55 0%, transparent 60%),` +
    `linear-gradient(180deg, ${bg} 0%, ${a} 140%)`
  fallback.classList.add('shown')
  canvas.classList.remove('ready')
}

function toPreset(cfg) {
  const make = PRESETS[cfg.preset]
  if (!make) return null
  // opacity and blendMode are universal props, so they travel with the others.
  return {
    components: make(cfg.colors, cfg.speed).map(({ type, props, opacity, blendMode }, i) => ({
      type, id: `l${i}`, children: [],
      props: { ...props, ...(opacity !== undefined && { opacity }), ...(blendMode && { blendMode }) },
    })),
  }
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
    const renderer = instance.lunaRenderer && instance.lunaRenderer()
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

window.lunaWallpaper = {
  apply(cfg) {
    still = !!cfg.still
    const key = JSON.stringify({ ...cfg, still: undefined, intensity: undefined })
    document.documentElement.style.setProperty('--intensity', String(cfg.intensity))
    if (key === applied) { syncRunning(); return }
    applied = key
    building = building.then(() => build(cfg))
  },
  setActive(on) {
    active = !!on
    building.then(syncRunning)
  },
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
// visibility observer can't restart a wallpaper Luna has paused.
let resizeTimer = null
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer)
  resizeTimer = setTimeout(() => { if (shader) shader.resize(window.innerWidth, window.innerHeight) }, 60)
})
post({ state: 'loaded' })
