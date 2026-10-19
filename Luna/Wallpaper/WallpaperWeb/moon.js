// Luna's shader moon: a lit sphere with a soft terminator, limb darkening, procedural
// maria and craters, a slow phase drift and a faint glow. Hand-written WGSL on a tiny
// WebGPU loop; same window.lunaWallpaper API as the wallpaper page so Luna drives
// both the same way. Without WebGPU it reports "fallback" and Luna keeps the ASCII moon.

const WGSL = /* wgsl */ `
struct U { res: vec2f, time: f32, radius: f32, busy: f32 };
@group(0) @binding(0) var<uniform> u: U;

@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var p = array<vec2f, 3>(vec2f(-1.0, -3.0), vec2f(-1.0, 1.0), vec2f(3.0, 1.0));
  return vec4f(p[i], 0.0, 1.0);
}

fn hash(p: vec3f) -> f32 { return fract(sin(dot(p, vec3f(127.1, 311.7, 74.7))) * 43758.5453); }

fn noise(p: vec3f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let w = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(mix(hash(i), hash(i + vec3f(1, 0, 0)), w.x), mix(hash(i + vec3f(0, 1, 0)), hash(i + vec3f(1, 1, 0)), w.x), w.y),
    mix(mix(hash(i + vec3f(0, 0, 1)), hash(i + vec3f(1, 0, 1)), w.x), mix(hash(i + vec3f(0, 1, 1)), hash(i + vec3f(1, 1, 1)), w.x), w.y),
    w.z);
}

fn fbm(p: vec3f) -> f32 {
  var v = 0.0;
  var a = 0.5;
  var q = p;
  for (var k = 0; k < 4; k++) { v += a * noise(q); q = q * 2.03 + vec3f(1.7, 9.2, 3.1); a *= 0.5; }
  return v;
}

// Small bowl-shaped craters from a jittered 3D cell grid.
fn craters(p: vec3f) -> f32 {
  let c = floor(p);
  var shade = 0.0;
  for (var x = -1; x <= 1; x++) { for (var y = -1; y <= 1; y++) { for (var z = -1; z <= 1; z++) {
    let cell = c + vec3f(f32(x), f32(y), f32(z));
    let h = hash(cell);
    if (h > 0.55) {
      let center = cell + vec3f(hash(cell + 3.1), hash(cell + 7.7), hash(cell + 1.3));
      let r = 0.18 + 0.25 * hash(cell + 5.5);
      let d = length(p - center) / r;
      shade += (smoothstep(1.0, 0.6, d) * -0.35 + smoothstep(1.15, 0.95, d) * smoothstep(0.85, 1.0, d) * 0.25);
    }
  }}}
  return shade;
}

@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  var q = (pos.xy - u.res * 0.5) / u.radius;
  q.y = -q.y;
  let r = length(q);
  let t = u.time;

  // Light from behind and to the side: a crescent that slowly swells and thins.
  let swell = 0.5 + 0.5 * sin(t * 0.07);
  let L = normalize(vec3f(0.95, 0.22 + 0.06 * sin(t * 0.05), mix(-0.75, -0.05, swell)));
  let moonlight = vec3f(0.96, 0.95, 0.90);

  // Faint glow, stronger on the lit side.
  let side = max(dot(normalize(q), normalize(L.xy)), 0.0);
  // Fades out radially by the largest circle that fits the frame. Fading by distance to the
  // frame edges instead traced a rounded box around the moon, with visible corners.
  let fit = min(u.res.x, u.res.y) * 0.5 / u.radius;
  let glow = exp(-max(r - 1.0, 0.0) * 9.0) * (0.04 + 0.16 * side) * smoothstep(0.98, 1.02, r)
    * smoothstep(fit, 1.0, r);

  if (r >= 1.0 + 2.0 / u.radius) {
    let g = glow * 0.9;
    return vec4f(moonlight * g, g);
  }

  let n = vec3f(q, sqrt(max(1.0 - r * r, 0.0)));
  // Libration: the surface turns slowly under the light.
  let a = t * (0.03 + 0.09 * u.busy);
  let ca = cos(a);
  let sa = sin(a);
  let p = vec3f(ca * n.x + sa * n.z, n.y * 0.98 + 0.12 * sin(t * 0.04) * n.z, -sa * n.x + ca * n.z);

  let maria = smoothstep(0.48, 0.66, fbm(p * 1.8 + vec3f(4.0, 1.0, 2.0)));
  var albedo = mix(1.0, 0.58, maria) * (0.82 + 0.3 * fbm(p * 7.0));
  albedo += craters(p * 5.0) * 0.6 + craters(p * 11.0) * 0.3;

  let ndl = dot(n, L);
  let lit = smoothstep(-0.06, 0.32, ndl) * (0.35 + 0.65 * max(ndl, 0.0));
  let limb = mix(0.62, 1.0, pow(n.z, 0.45));
  let earthshine = vec3f(0.11, 0.13, 0.18) * (0.6 + 0.4 * albedo);

  let color = moonlight * clamp(albedo, 0.2, 1.2) * lit * limb + earthshine * (1.0 - lit);
  let edge = smoothstep(1.0 + 1.5 / u.radius, 1.0 - 1.5 / u.radius, r);
  let alpha = edge * clamp(0.35 + lit * 1.4, 0.0, 1.0);
  let g = glow * (1.0 - edge);
  return vec4f(color * alpha + moonlight * g, alpha + g);
}
`

const canvas = document.getElementById('moon')
const post = (msg) => { try { window.webkit.messageHandlers.lunaWallpaper.postMessage(msg) } catch { /* not in Luna */ } }

let device = null
let context = null
let pipeline = null
let bind = null
let ubuf = null
let fps = 30
let still = false
let active = false
let busy = 0
let clock = 40          // seconds of moon time; only advances while animating
let last = null
let lastDraw = 0
let raf = null

async function init() {
  if (!navigator.gpu) return false
  const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'low-power' })
  if (!adapter) return false
  device = await adapter.requestDevice()
  context = canvas.getContext('webgpu')
  const format = navigator.gpu.getPreferredCanvasFormat()
  context.configure({ device, format, alphaMode: 'premultiplied' })
  const module = device.createShaderModule({ code: WGSL })
  pipeline = device.createRenderPipeline({
    layout: 'auto',
    vertex: { module, entryPoint: 'vs' },
    fragment: { module, entryPoint: 'fs', targets: [{ format }] },
    primitive: { topology: 'triangle-list' },
  })
  ubuf = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST })
  bind = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [{ binding: 0, resource: { buffer: ubuf } }] })
  device.lost.then(() => { device = null; post({ state: 'fallback', reason: 'device-lost' }) })
  return true
}

function resize() {
  const dpr = window.devicePixelRatio || 1
  const w = Math.max(1, Math.round(canvas.clientWidth * dpr))
  const h = Math.max(1, Math.round(canvas.clientHeight * dpr))
  if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h }
}

function draw() {
  if (!device) return
  resize()
  // Same proportions as the ASCII moon: its frame is 1.3 × 1.15 diameters.
  const radius = Math.min(canvas.width / 1.3, canvas.height / 1.15) / 2
  device.queue.writeBuffer(ubuf, 0, new Float32Array([canvas.width, canvas.height, clock, radius, busy, 0, 0, 0]))
  const enc = device.createCommandEncoder()
  const pass = enc.beginRenderPass({ colorAttachments: [{
    view: context.getCurrentTexture().createView(), loadOp: 'clear', storeOp: 'store', clearValue: { r: 0, g: 0, b: 0, a: 0 },
  }] })
  pass.setPipeline(pipeline)
  pass.setBindGroup(0, bind)
  pass.draw(3)
  pass.end()
  device.queue.submit([enc.finish()])
}

function frame(now) {
  raf = null
  if (!active || still) { last = null; return }
  raf = requestAnimationFrame(frame)
  if (now - lastDraw < 1000 / fps - 1) return
  const dt = last === null ? 0 : Math.min(0.1, (now - last) / 1000)
  last = now
  lastDraw = now
  clock += dt
  draw()
}

function sync() {
  if (active && !still) { if (raf === null) raf = requestAnimationFrame(frame) }
  else { if (raf !== null) cancelAnimationFrame(raf); raf = null; last = null; draw() }
}

const ready = init().then((ok) => {
  if (!ok) { post({ state: 'fallback', reason: 'unsupported' }); return false }
  canvas.classList.add('ready')
  draw()
  post({ state: 'running', preset: 'moon' })
  return true
}).catch((e) => { post({ state: 'fallback', reason: String(e && e.message || e) }); return false })

window.lunaWallpaper = {
  apply(cfg) {
    fps = cfg.fps === 60 ? 60 : 30
    still = !!cfg.still
    busy = cfg.busy ? 1 : 0
    ready.then((ok) => ok && sync())
  },
  setActive(on) {
    active = !!on
    ready.then((ok) => ok && sync())
  },
}
window.addEventListener('resize', () => { if (device) draw() })
post({ state: 'loaded' })
