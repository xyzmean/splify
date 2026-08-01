// Guards the contract between this build and build.sh / the LuCI loader shims.
//
// build.sh copies dist/* into the package and then rewrites `./splify-x.js?v=…`
// inside the two entry bundles to pin entry+chunk to one release. The loader
// shims (htdocs/…/view/splify/main.js and advanced.js) load splify-index.js and
// splify-settings.js by name. All three names are therefore load-bearing, and
// rollup will happily rename a shared chunk when the module graph shifts — which
// breaks the pinning silently, with no build error and a page that works until
// someone's cache serves a mismatched pair.
import { readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const DIST = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist')
const EXPECTED_JS = ['splify-index.js', 'splify-settings.js', 'splify-x.js']

const js = readdirSync(DIST).filter((f) => f.endsWith('.js')).sort()
const missing = EXPECTED_JS.filter((f) => !js.includes(f))
const extra = js.filter((f) => !EXPECTED_JS.includes(f))

const problems = []
if (missing.length) problems.push(`missing: ${missing.join(', ')}`)
if (extra.length) problems.push(`unexpected chunk(s): ${extra.join(', ')}`)

// Both entries must reference the shared chunk through the pinnable placeholder.
for (const entry of ['splify-index.js', 'splify-settings.js']) {
  if (!js.includes(entry)) continue
  const text = readFileSync(join(DIST, entry), 'utf8')
  if (!text.includes('./splify-x.js?v=')) {
    problems.push(`${entry} does not import ./splify-x.js?v= — build.sh cannot pin the chunk version`)
  }
}

if (problems.length) {
  console.error('✗ dist layout drifted from what build.sh expects:')
  for (const p of problems) console.error(`  - ${p}`)
  console.error('\nFix the manualChunks() mapping in vite.config.ts (see its comment).')
  process.exit(1)
}
console.log(`✓ dist layout OK (${js.join(', ')})`)
