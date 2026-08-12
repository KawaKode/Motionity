#!/usr/bin/env node
// Downloads every third-party asset that index.html used to pull from a CDN
// into src/vendor/, so the app runs with no network access. Run once before
// packaging (npm run vendor); the directory is gitignored.
//
// The only runtime network dependency left after this is the Google Fonts
// family the user picks in the text panel (WebFont.load), which degrades to a
// fallback font when offline.

import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const vendorDir = join(root, 'src', 'vendor');
const fontsDir = join(vendorDir, 'fonts');

// A desktop UA is required for the Google Fonts API to answer with woff2
// instead of the ancient truetype payload.
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const assets = [
  {
    url: 'https://cdnjs.cloudflare.com/ajax/libs/bodymovin/5.9.6/lottie.min.js',
    file: 'lottie.min.js',
  },
  {
    url: 'https://cdn.jsdelivr.net/npm/@simonwep/selection-js/lib/selection.min.js',
    file: 'selection.min.js',
  },
  {
    url: 'https://ajax.googleapis.com/ajax/libs/jquery/3.5.1/jquery.min.js',
    file: 'jquery.min.js',
  },
  {
    url: 'https://cdn.jsdelivr.net/npm/@simonwep/pickr/dist/pickr.min.js',
    file: 'pickr.min.js',
  },
  {
    url: 'https://cdn.jsdelivr.net/npm/@simonwep/pickr/dist/themes/nano.min.css',
    file: 'pickr-nano.min.css',
  },
  {
    url: 'https://cdnjs.cloudflare.com/ajax/libs/fabric.js/460/fabric.min.js',
    file: 'fabric.min.js',
  },
  {
    url: 'https://ajax.googleapis.com/ajax/libs/webfont/1.6.26/webfont.js',
    file: 'webfont.js',
  },
  {
    // ~18.5 MB asm.js build of ffmpeg, used by converter.js for MP4/GIF export.
    url: 'https://archive.org/download/ffmpeg_asm/ffmpeg_asm.js',
    file: 'ffmpeg_asm.js',
    optional: true,
  },
];

const fontCss =
  'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap';

async function fetchBuffer(url) {
  const res = await fetch(url, { headers: { 'user-agent': UA } });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${url}`);
  return Buffer.from(await res.arrayBuffer());
}

function human(bytes) {
  return bytes > 1e6
    ? `${(bytes / 1e6).toFixed(1)} MB`
    : `${Math.round(bytes / 1024)} KB`;
}

async function download(url, dest, { force }) {
  if (!force && existsSync(dest) && statSync(dest).size > 0) {
    console.log(`  skip  ${dest.slice(root.length + 1)} (already vendored)`);
    return;
  }
  const buf = await fetchBuffer(url);
  await writeFile(dest, buf);
  console.log(`  get   ${dest.slice(root.length + 1)} (${human(buf.length)})`);
}

// Rewrites the remote font files referenced by the Google Fonts stylesheet to
// local copies so no request leaves the machine at startup.
async function vendorFonts({ force }) {
  const dest = join(vendorDir, 'inter.css');
  if (!force && existsSync(dest) && statSync(dest).size > 0) {
    console.log(`  skip  src/vendor/inter.css (already vendored)`);
    return;
  }
  let css = (await fetchBuffer(fontCss)).toString('utf8');
  const urls = [...new Set([...css.matchAll(/url\((https:[^)]+)\)/g)].map((m) => m[1]))];
  for (const url of urls) {
    const ext = url.split('.').pop().split('?')[0];
    const name = `inter-${createHash('sha1').update(url).digest('hex').slice(0, 10)}.${ext}`;
    await writeFile(join(fontsDir, name), await fetchBuffer(url));
    css = css.split(url).join(`fonts/${name}`);
  }
  await writeFile(dest, css);
  console.log(`  get   src/vendor/inter.css (+${urls.length} font files)`);
}

const force = process.argv.includes('--force');
// Docker builds can drop the 18.5 MB ffmpeg blob; MP4/GIF export then falls
// back to fetching it from the public mirror at conversion time.
const skipOptional = process.argv.includes('--skip-ffmpeg');

await mkdir(fontsDir, { recursive: true });
console.log(`Vendoring third-party assets into src/vendor/`);
for (const asset of assets) {
  if (asset.optional && skipOptional) {
    console.log(`  omit  src/vendor/${asset.file} (--skip-ffmpeg)`);
    continue;
  }
  await download(asset.url, join(vendorDir, asset.file), { force });
}
await vendorFonts({ force });

// Sanity check: index.html must not have regained a CDN reference.
const html = await readFile(join(root, 'src', 'index.html'), 'utf8');
const remote = [...html.matchAll(/(?:src|href)="(https?:\/\/[^"]+)"/g)]
  .map((m) => m[1])
  .filter((u) => !/github\.com|motionity\.app|twitter\.com/.test(u));
if (remote.length) {
  console.warn(`\nWARNING: index.html still loads remote assets:`);
  for (const u of remote) console.warn(`  ${u}`);
  process.exitCode = 1;
} else {
  console.log(`\nDone. index.html loads no remote assets.`);
}
