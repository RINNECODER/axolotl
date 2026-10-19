// Builds Luna/Wallpaper/WallpaperWeb/shaders.js: the MIT `shaders` library (https://github.com/shader-effects-inc/shaders)
// trimmed to the components Luna's wallpapers use, with telemetry stubbed out so the
// wallpaper never talks to the network.
//
//   cd scripts/wallpaper && npm install --no-save shaders@4.0.4 esbuild@0.25.10 && node build.mjs
//
// The output is committed; node_modules is not.
import * as esbuild from 'esbuild'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import fs from 'node:fs'

const here = path.dirname(fileURLToPath(import.meta.url))
const out = path.resolve(here, '../../Luna/Wallpaper/WallpaperWeb/shaders.js')
const dist = path.resolve(here, 'node_modules/shaders/dist')

// Keep in sync with the component types used in Luna/Wallpaper/WallpaperWeb/wallpaper.js.
export const COMPONENTS = [
  'Aurora', 'Dither', 'FilmGrain', 'FloatingParticles', 'FlowingGradient', 'Fog', 'Godrays',
  'Halftone', 'LinearGradient', 'Marble', 'MeshGradient', 'Plasma', 'RadialGradient',
  'SimplexNoise', 'SineWave', 'SolidColor', 'Vignette',
]

const registry = COMPONENTS.map((n, i) =>
  `import { componentDefinition as c${i} } from ${JSON.stringify(`${dist}/core/shaders/${n}/index.js`)}`).join('\n') +
  `\nconst defs = [${COMPONENTS.map((_, i) => `c${i}`).join(', ')}]` +
  `\nconst entries = defs.map(d => ({ name: d.name, fileName: d.name, category: d.category || 'Uncategorized', definition: d, propsMetadata: {} }))` +
  `\nexport const shaderRegistry = Object.fromEntries(entries.map(e => [e.name, e]))` +
  `\nexport function getAllShaders() { return entries }` +
  `\nexport function getShaderByName(n) { return shaderRegistry[n] }` +
  `\nexport function getShadersByCategory(c) { return entries.filter(e => e.category === c) }` +
  `\nexport function getShaderCategories() { return [...new Set(entries.map(e => e.category))].sort() }` +
  `\nexport { shaderRegistry as a, getShadersByCategory as i, getShaderByName as n, getShaderCategories as r, getAllShaders as t }\n`

const luna = {
  name: 'luna-trim',
  setup(build) {
    build.onResolve({ filter: /(core\/registry|shaderRegistry-[\w-]+)\.js$/ }, () => ({ path: 'luna-registry', namespace: 'luna' }))
    build.onResolve({ filter: /core\/telemetry\/index\.js$/ }, () => ({ path: 'luna-telemetry', namespace: 'luna' }))
    build.onLoad({ filter: /.*/, namespace: 'luna' }, (args) => ({
      resolveDir: here,
      contents: args.path === 'luna-registry'
        ? registry
        : 'export const isExternalUser = () => false\nexport const startTelemetry = () => null\n',
    }))
    // Expose the renderer so Luna can cap the frame rate and lower the resolution scale.
    build.onLoad({ filter: /js\/createShader\.js$/ }, (args) => {
      const src = fs.readFileSync(args.path, 'utf8')
      const patched = src.replace('getFailureReason: () => unavailable',
        'getFailureReason: () => unavailable,\n\t\tlunaRenderer: () => current ? current.renderer : null')
      if (patched === src) throw new Error('createShader.js changed; update the Luna patch')
      return { contents: patched, loader: 'js' }
    })
  },
}

await esbuild.build({
  stdin: {
    contents: `export { createShader } from ${JSON.stringify(`${dist}/js/createShader.js`)}\n` +
      `export { isWebGPUSupported } from ${JSON.stringify(`${dist}/core/index.js`)}\n`,
    resolveDir: here,
    loader: 'js',
  },
  bundle: true,
  format: 'esm',
  minify: true,
  legalComments: 'none',
  banner: { js: '/* shaders@4.0.4 (MIT, Copyright (c) 2026 Shader Effects Inc.), trimmed for Luna. See LICENSE-shaders.txt */' },
  target: 'safari18',
  outfile: out,
  plugins: [luna],
})
console.log(`wrote ${out} (${(fs.statSync(out).size / 1024).toFixed(0)} KB)`)
