// robot-peek gemini-app|perplexity [out.png]
// Saves a PNG of what the RUNNING robot's page shows right now. Read-only:
//  - does nothing (prints "idle") unless the robot's status file says a job is running (fresh heartbeat, live pid);
//  - talks to the robot's existing Chrome over the DevTools port: lists the open pages, takes ONE screenshot of the job page, disconnects;
//  - never opens a page, never navigates, never takes the robot mutex, never closes Chrome or the page; bounded by a hard timeout.
// Prints only the PNG path (never page text, URL or title).
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readRobotState, ROBOT_STATE_DIR } from '../robot-common/robot-status.mjs'

const HUB = join(dirname(fileURLToPath(import.meta.url)), '..')
const ROBOTS = {
  'gemini-app': { dir: 'gemini-app', host: 'gemini.google.com' },
  'perplexity-app': { dir: 'perplexity-app', host: 'perplexity.ai' },
}
const ALIAS = { gemini: 'gemini-app', 'gemini-app': 'gemini-app', perplexity: 'perplexity-app', 'perplexity-app': 'perplexity-app' }
const name = ALIAS[String(process.argv[2] ?? '').toLowerCase()]
if (!name) {
  console.error('Usage: robot-peek gemini-app|perplexity [out.png]')
  process.exit(2)
}
const out = process.argv[3] ?? join(ROBOT_STATE_DIR, `${name}-peek.png`)
const HARD_LIMIT_MS = 15000
const hard = setTimeout(() => {
  console.error('peek: timed out')
  process.exit(3)
}, HARD_LIMIT_MS)

const state = readRobotState(name)
if (!state.busy) {
  console.log(`${name}: idle (no job running)`)
  process.exit(0)
}

const { PORT } = await import(`../${ROBOTS[name].dir}/chrome.mjs`)
const base = `http://127.0.0.1:${PORT}`
let targets
try {
  targets = await (await fetch(`${base}/json/list`, { signal: AbortSignal.timeout(4000) })).json()
} catch {
  console.error(`${name}: Chrome not reachable on port ${PORT}`)
  process.exit(3)
}
const pages = targets.filter(t => t.type === 'page' && t.url.includes(ROBOTS[name].host))
const target = pages.at(-1) // the robot opens exactly one job page; the newest is the one
if (!target) {
  console.log(`${name}: no job page open right now`)
  process.exit(0)
}

const ws = new WebSocket(target.webSocketDebuggerUrl)
const png = await new Promise((resolve, reject) => {
  ws.onerror = () => reject(new Error('could not connect'))
  ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: 'Page.captureScreenshot', params: { format: 'png' } }))
  ws.onmessage = ev => {
    const msg = JSON.parse(String(ev.data))
    if (msg.id !== 1) return
    if (msg.error) reject(new Error('screenshot refused'))
    else resolve(Buffer.from(msg.result.data, 'base64'))
  }
}).catch(e => {
  console.error(`${name}: ${e.message}`)
  return null
})
try {
  ws.close()
} catch {
  // ignore
}
if (!png) process.exit(3)
mkdirSync(dirname(out), { recursive: true })
writeFileSync(out, png)
clearTimeout(hard)
console.log(`${name}: ${state.step} ${state.seconds}s -> ${out}`)
process.exit(0)
