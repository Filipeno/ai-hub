// One-time login: opens a normal Chrome window with the Perplexity robot's own profile at perplexity.ai.
// Sign in with your Perplexity account (Google/Apple/email all work in a normal window), send one test question, then close the window.
import { startChrome, PROFILE } from './chrome.mjs'

const started = await startChrome({ visible: true })
console.log(started ? `Chrome opened (Perplexity robot profile: ${PROFILE}).` : 'The Perplexity robot Chrome is already running; use its window.')
console.log('Sign in to Perplexity, ask one test question, then CLOSE that Chrome window. After that, jobs run hidden in the background.')
