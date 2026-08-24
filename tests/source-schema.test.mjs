// source/source.json must satisfy AltStore's schema.
//
// A malformed source does not error loudly — AltStore simply refuses to add it,
// or adds it and shows nothing, which reads as "the app is broken" rather than
// "the manifest is wrong". Cheaper to catch here.
//
// Required fields per https://faq.altstore.io/developers/make-a-source :
//   source:  name, apps, news
//   app:     name, bundleIdentifier, developerName, localizedDescription,
//            iconURL, versions
//   version: version, buildVersion, date, downloadURL, size
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const src = JSON.parse(readFileSync(path.join(ROOT, 'source', 'source.json'), 'utf8'));

test('source has the required top-level fields', () => {
  for (const k of ['name', 'apps', 'news']) {
    assert.ok(k in src, `source.json must define "${k}"`);
  }
  assert.ok(Array.isArray(src.apps) && src.apps.length > 0, 'apps must be a non-empty array');
  assert.ok(Array.isArray(src.news), 'news must be an array (may be empty)');
});

test('every app has the required fields', () => {
  for (const app of src.apps) {
    for (const k of ['name', 'bundleIdentifier', 'developerName', 'localizedDescription', 'iconURL', 'versions']) {
      assert.ok(k in app, `app "${app.name || '?'}" must define "${k}"`);
    }
    assert.ok(Array.isArray(app.versions), 'versions must be an array');
  }
});

test('bundleIdentifier is reverse-DNS and matches the source identifier', () => {
  const app = src.apps[0];
  assert.match(app.bundleIdentifier, /^[a-z0-9]+(\.[a-z0-9-]+)+$/i,
    'bundleIdentifier must be reverse-DNS; it is CASE-SENSITIVE and must equal '
    + 'the built app\'s CFBundleIdentifier exactly or AltStore installs nothing');
});

test('every version entry is complete and self-consistent', () => {
  for (const app of src.apps) {
    for (const v of app.versions) {
      for (const k of ['version', 'buildVersion', 'date', 'downloadURL', 'size']) {
        assert.ok(k in v, `${app.name} ${v.version || '?'} must define "${k}"`);
      }
      assert.equal(typeof v.size, 'number', 'size must be a NUMBER of bytes, not a string');
      assert.ok(v.size > 0, 'size must be > 0 — AltStore uses it for the progress bar and sanity');
      assert.ok(!Number.isNaN(Date.parse(v.date)), `date must be ISO 8601, got ${v.date}`);
    }
  }
});

test('every URL is https', () => {
  // iOS App Transport Security blocks plain http without an explicit
  // exception. Tailscale issues real certificates (`tailscale cert`), so there
  // is no reason for an http:// URL to appear here.
  const urls = [];
  if (src.iconURL) urls.push(src.iconURL);
  for (const app of src.apps) {
    urls.push(app.iconURL);
    for (const v of app.versions) urls.push(v.downloadURL);
  }
  const bad = urls.filter((u) => u && !/^https:\/\//.test(u));
  assert.deepEqual(bad, [], 'these must be https:// — iOS ATS will refuse plain http');
});

test('versions are ordered newest-first', () => {
  // AltStore offers versions[0]. A source sorted the other way advertises the
  // OLDEST build as current, which looks like "updates never arrive".
  for (const app of src.apps) {
    const dates = app.versions.map((v) => Date.parse(v.date));
    const sorted = [...dates].sort((a, b) => b - a);
    assert.deepEqual(dates, sorted,
      `${app.name}: versions must be newest-first — AltStore serves versions[0]`);
  }
});
