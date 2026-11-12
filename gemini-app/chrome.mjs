// Shared helpers: start the robot's own Chrome (a separate profile, signed in to your Google account) and connect to it.
// Settings come from <hub>\config.json (written by install.ps1): robotProfile, chromePath, robotPort. All optional.
import { spawn } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright-core'

const HERE = dirname(fileURLToPath(import.meta.url))
export const HUB = join(HERE, '..')

const config = (() => {
  try {
    return JSON.parse(readFileSync(join(HUB, 'config.json'), 'utf8'))
  } catch {
    return {}
  }
})()

export const PORT = Number(config.robotPort ?? 9223)
export const PROFILE = config.robotProfile ?? join(homedir(), '.gemini-app-profile')
// hl=en makes the page English; the robot picks menu entries by position and role, not by their words, so it also works in other languages.
export const APP = 'https://gemini.google.com/app?hl=en'

const CANDIDATES = [
  process.env.GEMINI_APP_CHROME,
  config.chromePath,
  join(process.env.PROGRAMFILES ?? 'C:\\Program Files', 'Google\\Chrome\\Application\\chrome.exe'),
  join(process.env['PROGRAMFILES(X86)'] ?? 'C:\\Program Files (x86)', 'Google\\Chrome\\Application\\chrome.exe'),
  join(process.env.LOCALAPPDATA ?? '', 'Google\\Chrome\\Application\\chrome.exe'),
  join(process.env['PROGRAMFILES(X86)'] ?? 'C:\\Program Files (x86)', 'Microsoft\\Edge\\Application\\msedge.exe'),
  join(process.env.PROGRAMFILES ?? 'C:\\Program Files', 'Microsoft\\Edge\\Application\\msedge.exe'),
]
export const CHROME = CANDIDATES.find(p => p && existsSync(p))

const sleep = ms => new Promise(r => setTimeout(r, ms))

export const isUp = async () => {
  try {
    const r = await fetch(`http://127.0.0.1:${PORT}/json/version`, { signal: AbortSignal.timeout(1500) })
    return r.ok
  } catch {
    return false
  }
}

// visible = true for the one-time login (a normal window, so Google does not see an automated browser).
export const startChrome = async ({ visible }) => {
  if (await isUp()) return false
  if (!CHROME) throw new Error('Chrome or Edge not found. Install Chrome, or set chromePath in config.json.')
  const args = [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${PROFILE}`,
    '--no-first-run',
    '--no-default-browser-check',
    ...(visible ? [APP] : ['--headless=new', '--disable-gpu', '--window-size=1280,900', '--lang=en-US', 'about:blank']),
  ]
  spawn(CHROME, args, { detached: true, stdio: 'ignore' }).unref()
  for (let i = 0; i < 40; i++) {
    if (await isUp()) return true
    await sleep(500)
  }
  throw new Error('Chrome did not start (is another Chrome window already using the robot profile?)')
}

export const connect = () => chromium.connectOverCDP(`http://127.0.0.1:${PORT}`)

// Headless Chrome announces itself as "HeadlessChrome"; send the user agent the normal window sends.
export const useNormalUserAgent = async (context, page) => {
  try {
    const session = await context.newCDPSession(page)
    const { userAgent } = await session.send('Browser.getVersion')
    await session.send('Emulation.setUserAgentOverride', { userAgent: userAgent.replace('HeadlessChrome', 'Chrome') })
  } catch {
    // keep the default
  }
}

export const stopChrome = async browser => {
  try {
    const s = await browser.newBrowserCDPSession()
    await s.send('Browser.close')
  } catch {
    // already gone
  }
}
