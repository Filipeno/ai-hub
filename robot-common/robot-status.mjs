// Live status of a browser robot, for the /robots command and the status-line badge.
//   const status = robotStatus('gemini-app')
//   status.start()            job begins (busy)         status.mark('answering')   new step label (fixed words only!)
//   status.finish(exitCode)   job ends (also runs by itself when the process exits normally)
// File: <hub>\state\robots\<robot>.json, written atomically (temp file + rename), refreshed every 5 s while busy.
// Readers must treat a dead pid or a heartbeat older than STALE_SECONDS as idle: a killed robot never gets to say "done".
// Never put task text or page text in here: only the robot name, a fixed step label, times and the result.
import { mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HUB = join(dirname(fileURLToPath(import.meta.url)), '..')
export const ROBOT_STATE_DIR = join(HUB, 'state', 'robots')
export const STALE_SECONDS = 30
const HEARTBEAT_MS = 5000
const now = () => Math.round(Date.now() / 1000)
const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)

// Reader: the status of a robot as it is NOW. Busy only when the file says busy AND the heartbeat is fresh AND the pid is alive.
export function readRobotState (robot) {
  let rec
  try {
    rec = JSON.parse(readFileSync(join(ROBOT_STATE_DIR, `${robot}.json`), 'utf8'))
  } catch {
    return { robot, busy: false, step: 'idle', last: null }
  }
  let alive = true
  try {
    process.kill(rec.pid, 0) // signal 0 only tests that the process exists
  } catch (e) {
    alive = e.code === 'EPERM'
  }
  const fresh = now() - (rec.heartbeat ?? 0) <= STALE_SECONDS
  const busy = Boolean(rec.busy) && alive && fresh
  return { ...rec, busy, step: busy ? rec.step : 'idle', seconds: busy ? now() - (rec.step_since ?? rec.started) : 0 }
}

export function robotStatus (robot) {
  const file = join(ROBOT_STATE_DIR, `${robot}.json`)
  let last = null
  try {
    last = JSON.parse(readFileSync(file, 'utf8')).last ?? null
  } catch {
    // first run
  }
  const rec = { robot, pid: process.pid, busy: false, step: 'idle', started: null, step_since: null, heartbeat: now(), last }
  let timer = null

  // Temp file + rename: a reader sees the old file or the new one, never half of one. On Windows the rename can fail for a moment
  // while a reader has the file open, so retry a few times; a lost heartbeat is harmless (the next one comes in 5 s).
  const write = () => {
    rec.heartbeat = now()
    const tmp = `${file}.${process.pid}.tmp`
    try {
      mkdirSync(ROBOT_STATE_DIR, { recursive: true })
      writeFileSync(tmp, JSON.stringify(rec))
      for (let i = 0; i < 5; i++) {
        try {
          renameSync(tmp, file)
          return
        } catch {
          pause(40)
        }
      }
      unlinkSync(tmp)
    } catch {
      // status is a convenience: never let it stop a job
    }
  }

  const api = {
    start () {
      rec.busy = true
      rec.started = rec.step_since = now()
      rec.step = 'starting'
      write()
      timer = setInterval(write, HEARTBEAT_MS)
      timer.unref()
      process.on('exit', code => api.finish(code))
    },
    mark (label) {
      rec.step = label
      rec.step_since = now()
      if (rec.busy) write()
    },
    finish (code) {
      if (!rec.busy) return
      clearInterval(timer)
      rec.busy = false
      rec.step = 'idle'
      rec.last = { ok: code === 0, code, at: now() }
      write()
    },
  }
  return api
}
