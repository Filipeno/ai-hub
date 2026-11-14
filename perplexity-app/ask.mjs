// Send one question to Perplexity (perplexity.ai) in the robot's hidden Chrome and save the answer with its sources.
//   node ask.mjs --task "<question>" --out <answer file> [--timeout 120] [--model "<name>"]
//                [--file <local path>]... [--drive] [--incognito]
// Always uses Perplexity's normal Search mode (never Computer, Deep Research or Model Council: those are slow, agentic and limited).
// --model   a model from the Model menu by (part of) its name, e.g. "Claude Sonnet"; default "Best" (Perplexity decides).
//           The choice sticks in the profile, so every job sets it.
// --file    uploads a local file (PDF, text, images) before asking.
// --drive   turns on the Google Drive plugin for this question (the "@Google Drive" connector): Perplexity can then search and read
//           the files in your Drive (for example the folders you sync from your PC). Say which file you mean in the question.
// --incognito  asks Perplexity for an anonymous session; off by default (it adds about 8 s and was not reliable in tests).
// Exit codes: 0 answer saved | 2 bad arguments | 3 other failure | 4 not signed in | 5 Perplexity says limit reached | 7 Perplexity answered with an error
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { HUB, connect, startChrome, stopChrome, useNormalUserAgent, APP } from './chrome.mjs'

const arg = name => {
  const i = process.argv.indexOf(`--${name}`)
  return i > -1 ? process.argv[i + 1] : undefined
}
const all = name => process.argv.flatMap((a, i) => (a === `--${name}` && process.argv[i + 1] ? [process.argv[i + 1]] : []))
const task = arg('task')
const out = arg('out')
const modelArg = arg('model') ?? 'Best'
const localFiles = all('file')
const useDrive = process.argv.includes('--drive')
const incognito = process.argv.includes('--incognito')
const timeoutMs = Number(arg('timeout') ?? 120) * 1000
if (!task || !out) {
  console.error('Usage: node ask.mjs --task "<question>" --out <file> [--model "<name>"] [--file <path>]... [--drive]')
  process.exit(2)
}

const sleep = ms => new Promise(r => setTimeout(r, ms))
const T0 = Date.now()
let lastStep = 'start'
const mark = label => {
  lastStep = label
  if (process.env.ROBOT_DEBUG) console.error(`[${Math.round((Date.now() - T0) / 1000)}s] ${label}`)
}
// A normal click first (menu entries only react to a real one), then a forced click if the page is busy re-rendering.
const tap = async locator => {
  try {
    await locator.click({ timeout: 5000, noWaitAfter: true })
  } catch {
    await locator.click({ force: true, timeout: 5000, noWaitAfter: true })
  }
}
const SHOT = join(HUB, 'state', 'perplexity-app-last.png')
const LIMIT_RX = /(reached|hit) (your|the) (daily |weekly )?(limit|quota)|out of (pro )?(searches|queries)|upgrade to (continue|keep)|too many requests/i
const ERROR_RX = /something went wrong|try again later|an error occurred|couldn't (complete|process)/i

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
  await page.waitForLoadState('networkidle', { timeout: 8000 }).catch(() => {}) // a cold start keeps re-rendering for a while
  mark('page loaded')
  const composer = () => page.locator('div[role="textbox"]').first() // looked up fresh: the page re-renders it often
  await composer().waitFor({ state: 'visible', timeout: 30000 })
  // Signed out: Perplexity still answers anonymously, but the plan's models and limits do not apply, so treat it as not signed in.
  if ((await page.getByRole('button', { name: /^(sign in|log in|sign up)$/i }).count()) > 0 || (await page.getByRole('link', { name: /^(sign in|log in)$/i }).count()) > 0) {
    console.error('NOT SIGNED IN: run "perplexity-app login" once and sign in.')
    code = 4
    throw new Error('not signed in')
  }
  await page.keyboard.press('Escape') // closes any pop-up; nothing is ever accepted
  // Feature tips ("The Computer tab has moved...", 2026-11-14) sit over the composer's buttons and ignore Escape: click their X.
  for (let i = 0; i < 3; i++) {
    const x = page.getByRole('button', { name: /^(close|dismiss|got it|not now)$/i }).first()
    if (!(await x.isVisible().catch(() => false))) break
    await x.click({ timeout: 3000 }).catch(() => {})
    await sleep(600)
  }

  // Search mode, always. The page remembers the last mode and may open in Computer mode.
  const searchToggle = page.getByRole('button', { name: 'Search', exact: true }).first()
  // The toggle reports its state in aria-pressed. Only click when Search is not already on (a second click must not switch it off).
  for (let attempt = 0; attempt < 3 && (await searchToggle.getAttribute('aria-pressed')) !== 'true'; attempt++) {
    await tap(searchToggle).catch(() => {}) // the loop re-checks the state either way
    await sleep(1200)
  }
  if ((await searchToggle.getAttribute('aria-pressed')) !== 'true') throw new Error('could not switch to Search mode')
  mark('search mode')

  if (incognito) {
    const toggle = page.getByRole('button', { name: /incognito/i }).first()
    if (await toggle.isVisible().catch(() => false)) {
      await tap(toggle)
      await sleep(800)
    }
  }

  // Model: the menu button on the composer row, right of the Search/Computer toggle. Its label becomes the chosen model's name, so it is
  // found by position and by opening a menu, not by its text. Models are radios; match by name so a reordered menu still works.
  // On a cold start the page re-renders while it hydrates, so the button is located and clicked by its position on screen (a mouse
  // click at its centre), retried once, and a failure here never stops the job: the question is still asked with the current model.
  try {
    const toggleBox = await searchToggle.boundingBox()
    const modelButtonCentre = () =>
      page.evaluate(({ top, left }) => {
        const el = [...document.querySelectorAll('button[aria-haspopup="menu"]')]
          .filter(b => {
            const r = b.getBoundingClientRect()
            return r.width > 0 && Math.abs(r.top - top) < 30 && r.left > left + 100
          })
          .pop()
        if (!el) return null
        const r = el.getBoundingClientRect()
        return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
      }, { top: toggleBox.y, left: toggleBox.x })
    const item = page.locator('[role="menuitemradio"]').filter({ hasText: new RegExp(modelArg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i') }).first()
    let picked = false
    let seenMenu = false
    for (let attempt = 0; attempt < 2 && !picked; attempt++) {
      const c = await modelButtonCentre()
      if (!c) break
      await page.mouse.click(c.x, c.y)
      if ((await page.locator('[role="menuitemradio"]').first().waitFor({ state: 'visible', timeout: 4000 }).then(() => true, () => false))) {
        seenMenu = true
        if (await item.isVisible().catch(() => false)) {
          await tap(item)
          picked = true
        } else break
      } else {
        await page.keyboard.press('Escape')
        await sleep(1500)
      }
    }
    await sleep(600)
    if (picked) console.error(`MODEL: ${modelArg}`)
    else {
      console.error(seenMenu ? `MODEL: "${modelArg}" not in the menu (or locked on your plan); keeping the current model` : 'MODEL: could not open the model menu; keeping the current model')
      await page.keyboard.press('Escape')
    }
  } catch (e) {
    console.error(`MODEL: skipped (${String(e.message).split('\n')[0]})`)
    await page.keyboard.press('Escape').catch(() => {})
  }

  // Upload local files. The page has a hidden file input; fall back to the "+" menu's file chooser if it ever disappears.
  for (const path of localFiles) {
    const input = page.locator('input[type="file"]').first()
    if ((await input.count()) > 0) {
      await input.setInputFiles(path)
    } else {
      await tap(page.getByRole('button', { name: /add files, plugins/i }).first())
      const entry = page.locator('[role="option"], [role="menuitem"]').filter({ hasText: /add images and files|upload/i }).first()
      await entry.waitFor({ state: 'visible', timeout: 8000 })
      const [chooser] = await Promise.all([page.waitForEvent('filechooser', { timeout: 20000 }), entry.click({ timeout: 6000 })])
      await chooser.setFiles(path)
    }
    await sleep(5000)
  }

  await composer().waitFor({ state: 'visible', timeout: 30000 })
  await composer().click({ noWaitAfter: true })
  mark('composer ready')

  // Google Drive plugin: typing "@" opens the connector list; picking Google Drive adds it to this question.
  if (useDrive) {
    await page.keyboard.type('@', { delay: 60 })
    const drive = page.locator('[role="option"]').filter({ hasText: /^Google Drive/ }).first()
    if (await drive.waitFor({ state: 'visible', timeout: 8000 }).then(() => true, () => false)) {
      await tap(drive)
      await sleep(900)
      console.error('DRIVE: Google Drive plugin on')
    } else {
      console.error('DRIVE: the Google Drive plugin is not in the list (connect it in Perplexity first); asking without it')
      await page.keyboard.press('Backspace')
    }
  }

  await page.keyboard.insertText(task)
  await sleep(400)
  await page.keyboard.press('Enter')
  mark('submitted')

  // Wait for the answer: it appears in .prose; the answer's Copy button / "Finished" label shows when it is done; then the text must stop changing.
  const deadline = Date.now() + timeoutMs
  let last = ''
  let stable = 0
  let polls = 0
  while (Date.now() < deadline) {
    await sleep(1500)
    polls++
    const text = (await page.locator('.prose').last().innerText().catch(() => '')).trim()
    if (!text) {
      if (polls >= 8) {
        const body = await page.locator('main').innerText().catch(() => '')
        if (LIMIT_RX.test(body)) {
          console.error('LIMIT: Perplexity says a usage limit is reached.')
          code = 5
          throw new Error('limit')
        }
      }
      continue
    }
    const finished = (await page.getByRole('button', { name: /^copy$/i }).count()) > 0 || (await page.getByText(/^Finished\b/).count()) > 0
    stable = text === last && (finished || stable >= 4) ? stable + 1 : text === last ? stable + 0.5 : 0
    last = text
    if (stable >= 2) break
  }
  mark('answer done')
  if (!last) throw new Error('no answer before the timeout')
  if (last.length < 200 && ERROR_RX.test(last)) {
    console.error('APP ERROR: Perplexity replied with an error message.')
    code = 7
    throw new Error('app error')
  }

  // Sources: the "Sources" card on the right lists them; read its links (title = the second text line of each link).
  let sources = []
  try {
    const card = page.getByText(/^sources$/i).first()
    if (await card.isVisible().catch(() => false)) {
      await card.click({ timeout: 4000, force: true, noWaitAfter: true }).catch(() => {})
      await sleep(1200)
    }
    sources = await page.evaluate(() => {
      const seen = new Set()
      return [...document.querySelectorAll('a[href^="http"]')]
        .filter(a => a.getBoundingClientRect().width > 0 && !a.href.includes('perplexity.ai'))
        .map(a => ({ url: a.href, lines: (a.innerText || '').split('\n').map(s => s.trim()).filter(Boolean) }))
        .filter(s => !seen.has(s.url) && seen.add(s.url))
        .slice(0, 8)
        .map(s => ({ url: s.url, title: (s.lines[1] ?? s.lines[0] ?? s.url).slice(0, 90) }))
    })
  } catch {
    // an answer without a sources list is still an answer
  }
  mark('sources read')
  const answer = last.split('\n').map(l => l.replace(/\s+$/, '')).join('\n').trim()
  const text = sources.length ? `${answer}\n\nSources:\n${sources.map(s => `- ${s.title} - ${s.url}`).join('\n')}` : answer
  mkdirSync(dirname(out), { recursive: true })
  writeFileSync(out, text + '\n')
  console.log(`OK out=${out}`)
  code = 0
} catch (e) {
  // One line, so the job log shows the cause and not Playwright's multi-line call log.
  if (code === 3) console.error(`FAILED: ${String(e.message).split('\n')[0]} (step: ${lastStep})`)
  try {
    mkdirSync(dirname(SHOT), { recursive: true })
    // Bounded: a frozen page must not hang the job's exit.
    await Promise.race([page?.screenshot({ path: SHOT }), sleep(8000)])
    if (process.env.ROBOT_DEBUG && page) {
      const seen = await Promise.race([page.evaluate(() => [...document.querySelectorAll('button')].map(b => (b.getAttribute('aria-label') || b.innerText || '').trim().slice(0, 20)).filter(Boolean).slice(0, 40).join(' | ')), sleep(5000).then(() => 'page frozen')])
      console.error(`DEBUG url=${page.url()} buttons: ${seen}`)
    }
  } catch {
    // no page to shoot
  }
} finally {
  try {
    await page?.close()
  } catch {
    // ignore
  }
  // Closing the browser drops the connection; do not wait for a reply that never comes.
  if (startedHere) await Promise.race([stopChrome(browser), sleep(3000)])
  else await Promise.race([browser.close().catch(() => {}), sleep(3000)])
}
process.exit(code)
