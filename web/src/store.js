// Cached reads from the Toolbelt gateway, with the age of the data attached.
//
// The phone is NOT always on the tailnet — the owner connects deliberately. So
// every read has three possible outcomes, and the UI must be able to tell them
// apart:
//
//   fresh   — fetched just now from the gateway
//   cached  — the gateway is unreachable, showing what we last saw, WITH ITS AGE
//   none    — unreachable and nothing cached; say so, do not invent a state
//
// The failure this exists to prevent: showing a cached "all services healthy"
// from two days ago as if it were live. That is the same false-clean rule the
// parent repo enforces — a reading that could not be taken is reported as
// unknown, never as good news.

const DB = 'toolbelt-cache';
const STORE = 'reads';

function idb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function put(key, value) {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).put({ value, at: Date.now() }, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function get(key) {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readonly');
    const req = tx.objectStore(STORE).get(key);
    req.onsuccess = () => resolve(req.result || null);
    req.onerror = () => reject(req.error);
  });
}

/** Human age, deliberately coarse — false precision on staleness helps nobody. */
export function describeAge(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 90) return 'just now';
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h}h ago`;
  return `${Math.floor(h / 24)} days ago`;
}

/**
 * Read `path` from the gateway, falling back to cache.
 *
 * @returns {Promise<{state:'fresh'|'cached'|'none', data:any, at:number|null, ageText:string|null, error:string|null}>}
 */
export async function read(base, path, { timeoutMs = 4000 } = {}) {
  const key = `${base}${path}`;
  const ctrl = new AbortController();
  // A phone off the tailnet does not refuse the connection, it HANGS — the
  // packets go nowhere. Without a timeout the UI sits on a spinner forever,
  // which reads as "broken app" rather than "not connected".
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(key, { signal: ctrl.signal, cache: 'no-store' });
    if (!res.ok) throw new Error(`gateway returned ${res.status}`);
    const data = await res.json();
    await put(key, data);
    return { state: 'fresh', data, at: Date.now(), ageText: 'just now', error: null };
  } catch (err) {
    const cached = await get(key).catch(() => null);
    if (cached) {
      return {
        state: 'cached',
        data: cached.value,
        at: cached.at,
        ageText: describeAge(Date.now() - cached.at),
        error: String(err && err.message || err),
      };
    }
    return {
      state: 'none',
      data: null,
      at: null,
      ageText: null,
      error: String(err && err.message || err),
    };
  } finally {
    clearTimeout(timer);
  }
}
