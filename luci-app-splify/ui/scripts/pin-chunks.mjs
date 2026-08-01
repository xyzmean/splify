// Appends the cache-busting placeholder to every chunk an entry bundle imports.
//
// build.sh later rewrites "?v=0.0.0" to the release version, which is what keeps a
// stale HTTP cache from pairing a new entry bundle with an old chunk. That used to
// be a one-line sed for splify-x.js only; lazily loaded tabs are imported with
// BACKTICK-quoted specifiers (`import(`./splify-WgPanel.js`)`), and a backtick
// inside an npm script breaks the shell before sed ever runs — hence a script.
//
// scripts/check-dist.mjs verifies the result, so a chunk that slips through here
// fails the build instead of shipping unpinned.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const DIST = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist')
const ENTRIES = ['splify-index.js', 'splify-settings.js']
const REF = /(["'`])(\.\/splify-[A-Za-z0-9_-]+\.js)\1/g

let pinned = 0
for (const entry of ENTRIES) {
  if (!readdirSync(DIST).includes(entry)) continue
  const path = join(DIST, entry)
  const before = readFileSync(path, 'utf8')
  const after = before.replace(REF, (_m, q, name) => {
    pinned++
    return `${q}${name}?v=0.0.0${q}`
  })
  if (after !== before) writeFileSync(path, after)
}
console.log(`✓ pinned ${pinned} chunk reference(s) with ?v=`)
