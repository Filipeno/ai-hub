// Send one prompt to the Gemini app (gemini.google.com) in the robot's hidden Chrome and save the answer.
//   node ask.mjs --task "<prompt>" --out <answer file> [--timeout 300] [--model lite|flash|pro] [--think low|medium|high]
//                [--file <local path>]... [--drive "<file name in Google Drive>"]...
// --model picks the model by its place in the app's menu (1st = fastest, 2nd = everyday, 3rd = most capable), not by its name, so it
//         keeps working when Google renames the models or the app is not in English. --think sets the thinking level the same way.
// --file  uploads a local file straight from this PC (repeatable; text/code/PDF, a few MB each).
// --drive attaches a file from your Google Drive with Gemini's own picker (repeatable; first search match is used).
// Exit codes: 0 answer saved | 2 bad arguments | 3 other failure | 4 not signed in | 5 Gemini app says limit reached | 6 Drive file not found | 7 Gemini answered with an error message
import { mkdirSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { HUB, connect, startChrome, stopChrome, useNormalUserAgent, APP } from './chrome.mjs'

const arg = name => {
  const i = process.argv.indexOf(`--${name}`)
  return i > -1 ? process.argv[i + 1] : undefined
}
const all = name => process.argv.flatMap((a, i) => (a === `--${name}` && process.argv[i + 1] ? [process.argv[i + 1]] : []))
const driveFiles = all('drive')
const localFiles = all('file')
const modelArg = arg('model') // lite | flash | pro
const thinkArg = arg('think') // low | medium | high
const task = arg('task')
const out = arg('out')
const timeoutMs = Number(arg('timeout') ?? 300) * 1000
if (!task || !out) {
  console.error('Usage: node ask.mjs --task "<prompt>" --out <file> [--timeout 300]')
  process.exit(2)
}

const sleep = ms => new Promise(r => setTimeout(r, ms))
const SHOT = join(HUB, 'state', 'gemini-app-last.png')
const LIMIT_RX = /(reached|hit) (your|the) (daily )?(limit|usage)|usage limit|come back (later|tomorrow)|try again (later|tomorrow)|too many requests/i
const MODEL_INDEX = { lite: 0, flash: 1, pro: 2 }
const LEVEL_INDEX = { low: 0, medium: 1, high: 2 }

const startedHere = await startChrome({ visible: false })
const browser = await connect()
let page
let code = 3
try {
  const context = browser.contexts()[0] ?? (await browser.newContext())
  page = await context.newPage()
  await useNormalUserAgent(context, page)
  await page.setViewportSize({ width: 1280, height: 900 })
  await page.goto(APP, { waitUntil: 'domcontentloaded' })
  await sleep(3000)
  const composerSel = 'div.ql-editor[contenteditable="true"], rich-textarea [contenteditable="true"], [role="textbox"]'
  const signedOut = page.url().includes('accounts.google.com') || (await page.locator('a[href*="accounts.google.com/ServiceLogin"]').count()) > 0
  if (signedOut) {
    console.error('NOT SIGNED IN: run "gemini-app login" once and sign in.')
    code = 4
    throw new Error('not signed in')
  }

  // Dismiss pop-ups that cover the page (location, tips): Escape first, then a Close button. Never accept or allow anything.
  for (let i = 0; i < 3; i++) {
    if ((await page.locator('.cdk-overlay-container [role="dialog"], .cdk-overlay-container mat-dialog-container').count()) === 0) break
    await page.keyboard.press('Escape')
    await sleep(600)
    const close = page.locator('.cdk-overlay-container button').filter({ hasText: /^(Close|Dismiss|Not now|Zavřít|Teď ne)$/i }).first()
    if (await close.isVisible().catch(() => false)) await close.click().catch(() => {})
    await sleep(600)
  }

  // The mode picker (model + thinking level) and the "+" button next to it. Found by id and position, not by text.
  const picker = page.locator('[data-test-id="bard-mode-menu-button"]').first()
  const radios = page.locator('[role="menuitemradio"]')
  const openPicker = async () => {
    await picker.click()
    await sleep(800)
  }
  // Pick the model and thinking level in the app's own menu (the default is the biggest model on high, which is slow).
  if (modelArg in MODEL_INDEX) {
    await openPicker()
    await radios.nth(MODEL_INDEX[modelArg]).click()
    await sleep(900)
  }
  if (thinkArg in LEVEL_INDEX) {
    await openPicker()
    const trigger = page.locator('[role="menuitem"]').first() // "Thinking level" opens the sub-menu
    if (await trigger.isVisible().catch(() => false)) {
      await trigger.click()
      await sleep(800)
      const n = await radios.count()
      if (n >= 3) await radios.nth(n - 3 + LEVEL_INDEX[thinkArg]).click() // the last three radios are the levels
      await sleep(700)
    }
    await page.keyboard.press('Escape')
    await sleep(400)
  }
  if (modelArg || thinkArg) console.error(`MODE: ${((await picker.getAttribute('aria-label').catch(() => '')) ?? '').replace(/^Open mode picker, currently /i, '')}`)

  // The "+" (Upload & tools) button: the menu button on the picker's row, left of it.
  const openPlusMenu = async () => {
    const box = await picker.boundingBox()
    const buttons = page.locator('button[aria-haspopup="menu"]')
    const n = await buttons.count()
    let best = null
    for (let i = 0; i < n; i++) {
      const b = await buttons.nth(i).boundingBox()
      if (b && box && Math.abs(b.y - box.y) < 40 && b.x < box.x && (!best || b.x > best.x)) best = { x: b.x, i }
    }
    if (!best) throw new Error('could not find the Upload & tools button')
    await buttons.nth(best.i).click()
    await sleep(900)
  }
  const menuItems = page.locator('[role="menuitem"]')

  // Attach files from Google Drive through Gemini's own picker (2nd entry of the upload menu).
  for (const name of driveFiles) {
    await openPlusMenu()
    await menuItems.nth(1).click()
    const frame = page.frameLocator('iframe[src*="docs.google.com/picker"]')
    const search = frame.locator('input:visible:enabled').first()
    await search.waitFor({ state: 'visible', timeout: 30000 })
    await search.fill(name)
    await search.press('Enter')
    const hit = frame.getByText(name, { exact: true }).first()
    const found = await hit.waitFor({ state: 'visible', timeout: 15000 }).then(() => true, () => false)
    if (!found) {
      console.error(`DRIVE FILE NOT FOUND: ${name}`)
      code = 6
      throw new Error(`Drive file not found: ${name}`)
    }
    await hit.click()
    await frame.getByRole('button', { name: /^(Insert|Vložit|Select|Vybrat)/i }).click()
    await sleep(3500)
  }
  // Upload local files straight from the PC (1st entry of the upload menu), no Drive sync delay.
  for (const path of localFiles) {
    await openPlusMenu()
    const [chooser] = await Promise.all([page.waitForEvent('filechooser', { timeout: 20000 }), menuItems.nth(0).click()])
    await chooser.setFiles(path)
    await sleep(4000 + Math.ceil(statSync(path).size / 1048576) * 2500)
  }

  const box = page.locator(composerSel).first()
  await box.waitFor({ state: 'visible', timeout: 30000 })
  await box.click()
  const before = await page.locator('model-response').count()
  await page.keyboard.insertText(task)
  await sleep(400)
  await page.keyboard.press('Enter')

  // Wait for a new response to appear, then for its text to stop changing.
  const deadline = Date.now() + timeoutMs
  let last = ''
  let stable = 0
  let noAnswerPolls = 0
  while (Date.now() < deadline) {
    await sleep(1500)
    const count = await page.locator('model-response').count()
    if (count <= before) {
      // No answer yet. Only after about 10 s of nothing do we look for a limit message (the page also shows your own prompt).
      noAnswerPolls++
      const body = noAnswerPolls >= 7 ? await page.locator('body').innerText().catch(() => '') : ''
      if (body && LIMIT_RX.test(body)) {
        console.error('LIMIT: the Gemini app says the usage limit is reached.')
        code = 5
        throw new Error('limit')
      }
      continue
    }
    // The answer text lives in .model-response-text. It is done when the answer's action buttons (copy, good/bad response, ...)
    // have appeared: at least three buttons inside the last response. (.processing-state-visible never clears.)
    const text = (await page.locator('model-response .model-response-text').last().innerText().catch(() => '')).trim()
    const done = (await page.locator('model-response').last().locator('button').count()) >= 3
    stable = text && text === last && done ? stable + 1 : 0
    last = text
    if (stable >= 2) break
  }
  if (!last) throw new Error('no answer before the timeout')
  // Gemini sometimes answers with its own error text; that is a failed job, not an answer.
  if (last.length < 200 && /something went wrong|try your request again|encountering an error|try something else for you|can't help with that right now|něco se pokazilo|došlo k chybě/i.test(last)) {
    console.error('APP ERROR: Gemini replied with an error message.')
    code = 7
    throw new Error('app error')
  }
  // Drop code-block label lines the page adds ("TXT", "+ 2") and trailing spaces.
  const answer = last.split('\n').filter(l => !/^\s*(TXT|\+ \d+)\s*$/.test(l)).map(l => l.replace(/\s+$/, '')).join('\n').trim()
  mkdirSync(dirname(out), { recursive: true })
  writeFileSync(out, answer + '\n')
  console.log(`OK out=${out}`)
  code = 0
} catch (e) {
  if (code === 3) console.error(`FAILED: ${e.message}`)
  try {
    mkdirSync(dirname(SHOT), { recursive: true })
    await page?.screenshot({ path: SHOT })
  } catch {
    // no page to shoot
  }
} finally {
  try {
    await page?.close()
  } catch {
    // ignore
  }
  if (startedHere) await stopChrome(browser)
  else await browser.close().catch(() => {})
}
process.exit(code)
