#!/usr/bin/env node
// Add a built .ipa to source/source.json as a new version entry.
//
// AltStore reads the source JSON and offers whatever `versions[0]` says, so
// the entry has to describe the ACTUAL file — a wrong `size` or a stale
// `version` makes AltStore either refuse the download or install something
// other than what the manifest claims.
//
// Every field here is READ FROM THE BUILT ARTEFACT rather than passed in by
// hand: version and buildVersion come out of the .app's Info.plist inside the
// .ipa, size from the file on disk. Hand-typed metadata is how a source ends
// up advertising a version it does not actually serve.
//
// Usage:
//   node scripts/add-release.mjs <path-to.ipa> <downloadURL>
//
// Exits non-zero with a stated reason rather than writing a half-correct entry.
import { readFileSync, writeFileSync, statSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const [, , IPA, DOWNLOAD_URL] = process.argv;
const SOURCE = path.join(path.dirname(new URL(import.meta.url).pathname), '..', 'source', 'source.json');

function die(msg) {
  console.error(`[add-release] ${msg}`);
  process.exit(1);
}

if (!IPA || !DOWNLOAD_URL) die('usage: add-release.mjs <path-to.ipa> <downloadURL>');
if (!existsSync(IPA)) die(`no such file: ${IPA}`);
if (!/^https:\/\//.test(DOWNLOAD_URL)) {
  // AltStore will not fetch plain HTTP on a modern iOS without an ATS
  // exception. Tailscale hands out real certs via `tailscale cert`, so there
  // is no reason to accept http:// here.
  die(`downloadURL must be https:// — got ${DOWNLOAD_URL}`);
}

/** Pull CFBundleShortVersionString / CFBundleVersion out of the .ipa. */
function plistFromIpa(ipa) {
  // The .app name is not known up front, so list the archive and find the
  // Info.plist that sits directly inside Payload/<Something>.app/.
  const listing = execFileSync('unzip', ['-Z1', ipa], { encoding: 'utf8' });
  const entry = listing.split('\n').find((l) => /^Payload\/[^/]+\.app\/Info\.plist$/.test(l));
  if (!entry) die('no Payload/*.app/Info.plist inside the .ipa — is this really an ipa?');

  const raw = execFileSync('unzip', ['-p', ipa, entry], { encoding: 'buffer', maxBuffer: 32 * 1024 * 1024 });
  // Info.plist in a built .app is binary plist; plutil/plistutil may not exist
  // on Linux, so parse the two keys we need out of either form.
  const text = raw.toString('utf8');
  const xml = (key) => {
    const m = text.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`));
    return m ? m[1] : null;
  };
  let version = xml('CFBundleShortVersionString');
  let build = xml('CFBundleVersion');

  if (!version || !build) {
    // Binary plist: values sit as length-prefixed ASCII near their keys. Rather
    // than hand-rolling a bplist parser, ask the system tool if present.
    for (const tool of ['plutil', 'plistutil']) {
      try {
        const args = tool === 'plutil' ? ['-convert', 'xml1', '-o', '-', '-'] : ['-i', '-', '-o', '-'];
        const out = execFileSync(tool, args, { input: raw, encoding: 'utf8' });
        const g = (k) => (out.match(new RegExp(`<key>${k}</key>\\s*<string>([^<]+)</string>`)) || [])[1];
        version = version || g('CFBundleShortVersionString');
        build = build || g('CFBundleVersion');
        break;
      } catch { /* tool absent — fall through to the explicit failure below */ }
    }
  }
  if (!version || !build) {
    die('could not read CFBundleShortVersionString / CFBundleVersion from the .ipa.\n'
      + '  The Info.plist is a binary plist and neither plutil nor plistutil is available.\n'
      + '  Run this step on the macOS build runner (where plutil exists), not on Linux.');
  }
  return { version, build };
}

const { version, build } = plistFromIpa(IPA);
const size = statSync(IPA).size;

const src = JSON.parse(readFileSync(SOURCE, 'utf8'));
const app = src.apps[0];
if (!app) die('source.json has no apps[0]');

const entry = {
  version,
  buildVersion: build,
  date: new Date().toISOString(),
  downloadURL: DOWNLOAD_URL,
  size,
  localizedDescription: `Build ${build}.`,
};

// Newest first — AltStore offers versions[0].
const existing = app.versions.findIndex((v) => v.version === version && v.buildVersion === build);
if (existing !== -1) {
  console.log(`[add-release] replacing existing entry for ${version} (${build})`);
  app.versions.splice(existing, 1);
}
app.versions.unshift(entry);

writeFileSync(SOURCE, `${JSON.stringify(src, null, 2)}\n`);
console.log(`[add-release] ${app.bundleIdentifier} ${version} (${build}) — ${size} bytes`);
console.log(`[add-release] downloadURL: ${DOWNLOAD_URL}`);
