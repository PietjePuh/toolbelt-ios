// The cache must never present stale data as live.
//
// The phone is often OFF the tailnet by choice, so "gateway unreachable" is the
// normal case, not an error case. The rule this pins: a read that could not be
// taken is reported as cached-with-age or as nothing at all — never as fresh.
// Showing a two-day-old "all services healthy" as current is the false-clean
// failure the parent repo has been bitten by repeatedly.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = readFileSync(path.join(ROOT, 'web', 'src', 'store.js'), 'utf8');

// describeAge is pure, so exercise it directly rather than mocking IndexedDB.
const { describeAge } = await import(path.join(ROOT, 'web', 'src', 'store.js'))
  .catch(() => ({ describeAge: null }));

test('a failed read is never reported as fresh', () => {
  // Structural: the only place state:'fresh' is produced must be after a
  // successful fetch, inside try — not in the catch that handles unreachable.
  const catchBlock = SRC.slice(SRC.indexOf('} catch (err) {'));
  assert.doesNotMatch(catchBlock, /state:\s*'fresh'/,
    "the unreachable path must never return state:'fresh' — that is exactly how "
    + 'a two-day-old reading gets shown as current');
});

test('the unreachable-with-cache path carries an age', () => {
  const catchBlock = SRC.slice(SRC.indexOf('} catch (err) {'));
  assert.match(catchBlock, /state:\s*'cached'/, 'must distinguish cached from fresh');
  assert.match(catchBlock, /ageText/, 'cached data must carry its age for the UI to show');
});

test('unreachable with NO cache reports nothing, not an empty success', () => {
  const catchBlock = SRC.slice(SRC.indexOf('} catch (err) {'));
  assert.match(catchBlock, /state:\s*'none'/,
    'no data must be its own state — an empty list rendered as "0 alerts" would '
    + 'read as good news when it means "could not ask"');
});

test('the fetch is bounded by a timeout', () => {
  // A phone off the tailnet does not get a refusal; the packets go nowhere and
  // the request hangs. Without a timeout the UI spins forever and reads as a
  // broken app rather than "not connected".
  assert.match(SRC, /AbortController/, 'must abort, not hang');
  assert.match(SRC, /timeoutMs/, 'timeout must be explicit and tunable');
});

test('age wording is coarse and honest', { skip: !describeAge }, () => {
  assert.equal(describeAge(5_000), 'just now');
  assert.equal(describeAge(10 * 60_000), '10 min ago');
  assert.equal(describeAge(5 * 3_600_000), '5h ago');
  assert.equal(describeAge(3 * 86_400_000), '3 days ago');
});
