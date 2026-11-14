// Read-only: print the Gemini app's model menu as JSON (used by bin\selftest.ps1 to notice model changes). Sends no prompt.
//   node menu.mjs   ->  {"models":["3.5 Flash-Lite","4 Hydrogen","4 Argon"],"levels":["Low","Medium","High"],"current":"Hydrogen Medium"}
import { APP, isUp, startChrome, connect, useNormalUserAgent, stopChrome } from './chrome.mjs'
import { closePopups } from '../robot-common/robot-util.mjs'
const sleep = ms => new Promise(r => setTimeout(r, ms))
const wasUp = await isUp()
if (!wasUp) await startChrome({ visible: false })
const browser = await connect()
let page, code = 3
try {
  const context = browser.contexts()[0] ?? (await browser.newContext())
  page = await context.newPage()
  await useNormalUserAgent(context, page)
  await page.goto(APP, { waitUntil: 'domcontentloaded' })
  await sleep(5000)
  await closePopups(page)
  const picker = page.locator('[data-test-id="bard-mode-menu-button"]').first()
  await picker.waitFor({ state: 'visible', timeout: 20000 })
  const current = ((await picker.getAttribute('aria-label')) ?? '').replace(/^Open mode picker, currently /i, '')
  await picker.click()
  await sleep(1200)
  const radios = await page.locator('[role="menuitemradio"]').evaluateAll(els => els.map(e => e.innerText.replace(/\s+/g, ' ').trim()))
  await page.keyboard.press('Escape')
  // Model rows read "Quick answers 3.5 Flash-Lite": keep the model name (from the first digit on). Level rows read "Low Fast and efficient".
  const levels = radios.filter(t => /^(Low|Medium|High)\b/i.test(t)).map(t => t.split(' ')[0])
  const models = radios.filter(t => !/^(Low|Medium|High)\b/i.test(t)).map(t => (t.match(/\d.*$/) ?? [t])[0])
  console.log(JSON.stringify({ models, levels, current }))
  code = 0
} catch (e) {
  console.error(`FAILED: ${String(e.message).split('\n')[0]}`)
} finally {
  await page?.close().catch(() => {})
  if (!wasUp) await stopChrome(browser); else await browser.close().catch(() => {})
  process.exit(code)
}
