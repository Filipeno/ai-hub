// One-time login: opens a normal Chrome window with the robot's own profile at gemini.google.com.
// Sign in with the Google account that has your Gemini plan, send one test message, then close the window.
import { startChrome, PROFILE } from './chrome.mjs'

const started = await startChrome({ visible: true })
console.log(started ? `Chrome opened (robot profile: ${PROFILE}).` : 'The robot Chrome is already running; use its window.')
console.log('Sign in to Gemini, send one test message, then CLOSE that Chrome window. After that, jobs run hidden in the background.')
