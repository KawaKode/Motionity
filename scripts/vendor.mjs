#!/usr/bin/env node
// Downloads every third-party asset that index.html used to pull from a CDN
// into src/vendor/, so the app runs with no network access. Run once before
// packaging (npm run vendor); the directory is gitignored.
//
// The only runtime network dependency left after this is the Google Fonts
// family the user picks in the text panel (WebFont.load), which degrades to a
// fallback font when offline.

import { createHash } from 'node:crypto';
import { copyFile, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const vendorDir = join(root, 'src', 'vendor');
const fontsDir = join(vendorDir, 'fonts');
const ffmpegDir = join(vendorDir, 'ffmpeg');

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
];

// ffmpeg.wasm, used by converter.js for MP4/GIF export. Copied out of
// node_modules rather than downloaded: package-lock.json pins these by integrity
// hash, so the bytes that land in the image are the bytes npm verified. The
// asm.js build this replaced came from a public archive.org mirror with no
// integrity check at all.
//
// The loader's lazily-loaded webpack chunk has to sit beside it, and the core's
// .wasm and .worker.js beside ffmpeg-core.js — the loader derives both paths by
// substitution, so the layout is not negotiable.
const ffmpegFiles = [
  { from: '@ffmpeg/ffmpeg/dist/ffmpeg.min.js', to: 'ffmpeg.min.js' },
  { from: '@ffmpeg/ffmpeg/dist/046d0074eee1d99a674a.js', to: '046d0074eee1d99a674a.js' },
  { from: '@ffmpeg/core-st/dist/ffmpeg-core.js', to: 'ffmpeg-core.js' },
  { from: '@ffmpeg/core-st/dist/ffmpeg-core.worker.js', to: 'ffmpeg-core.worker.js' },
  // 23 MB, and the only reason --skip-ffmpeg exists.
  { from: '@ffmpeg/core-st/dist/ffmpeg-core.wasm', to: 'ffmpeg-core.wasm', heavy: true },
];

// core-st is the single-threaded core on purpose: the default @ffmpeg/core is
// built with pthreads and needs SharedArrayBuffer, which means COOP/COEP
// isolation, which would break the Pixabay, Unsplash and Google Fonts requests.
async function vendorFfmpeg({ skipHeavy }) {
  // An existing checkout still has the 18.5 MB asm.js blob the archive.org path
  // left behind. Nothing loads it any more, but src/vendor/ is packaged whole,
  // so it would ship in every installer until someone noticed.
  const legacy = join(vendorDir, 'ffmpeg_asm.js');
  if (existsSync(legacy)) {
    await rm(legacy);
    console.log('  prune src/vendor/ffmpeg_asm.js (replaced by ffmpeg.wasm)');
  }

  await mkdir(ffmpegDir, { recursive: true });
  for (const { from, to, heavy } of ffmpegFiles) {
    const src = join(root, 'node_modules', from);
    if (heavy && skipHeavy) {
      console.log(`  omit  src/vendor/ffmpeg/${to} (--skip-ffmpeg)`);
      continue;
    }
    if (!existsSync(src)) {
      throw new Error(
        `${from} is missing — run "npm install" before vendoring (ffmpeg.wasm now ` +
          `comes from node_modules, not a CDN).`
      );
    }
    await copyFile(src, join(ffmpegDir, to));
    console.log(`  copy  src/vendor/ffmpeg/${to} (${human(statSync(src).size)})`);
  }
}

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
// Docker builds can drop the 23 MB ffmpeg core. Unlike the old asm.js build
// there is no runtime mirror to fall back to, so this now means MP4/GIF export
// is unavailable in that image — converter.js says so rather than failing late.
const skipFfmpeg = process.argv.includes('--skip-ffmpeg');

await mkdir(fontsDir, { recursive: true });
console.log(`Vendoring third-party assets into src/vendor/`);
for (const asset of assets) {
  await download(asset.url, join(vendorDir, asset.file), { force });
}
await vendorFonts({ force });
await vendorFfmpeg({ skipHeavy: skipFfmpeg });

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
