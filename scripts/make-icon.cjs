#!/usr/bin/env node
// Renders build/icon.png (512x512) from the same geometry as
// src/assets/logo.svg: three white rounded bars on the app's dark background.
//
// Hand-rolled so packaging needs no image toolchain (no ImageMagick, no sharp).
// electron-builder derives the Windows .ico and the Linux icon set from it.

const { deflateSync } = require('node:zlib');
const { mkdirSync, writeFileSync } = require('node:fs');
const { join, resolve } = require('node:path');

const SIZE = 512;
const SS = 4; // supersampling factor, for antialiased edges
const BG = [0x14, 0x16, 0x29];
const FG = [0xff, 0xff, 0xff];
const BG_RADIUS = 96; // squircle-ish corner on the icon plate

// viewBox="0 0 24 19" in src/assets/logo.svg
const VIEW = { w: 24, h: 19 };
const BARS = [
  { x: 17.3193, y: 8.36011, w: 6.08, h: 10.64, r: 3.04 },
  { x: 8.95996, y: 0, w: 6.08, h: 19, r: 3.04 },
  { x: 0.599609, y: 0, w: 6.08, h: 19, r: 3.04 },
];

function insideRoundedRect(px, py, { x, y, w, h, r }) {
  const dx = Math.max(x + r - px, 0, px - (x + w - r));
  const dy = Math.max(y + r - py, 0, py - (y + h - r));
  return dx * dx + dy * dy <= r * r;
}

// The logo occupies 62% of the plate, centred.
const scale = (SIZE * 0.62) / VIEW.h;
const offsetX = (SIZE - VIEW.w * scale) / 2;
const offsetY = (SIZE - VIEW.h * scale) / 2;

const plate = { x: 0, y: 0, w: SIZE, h: SIZE, r: BG_RADIUS };

// Raw RGBA scanlines, each prefixed with filter type 0.
const raw = Buffer.alloc(SIZE * (1 + SIZE * 4));
for (let py = 0; py < SIZE; py++) {
  const rowStart = py * (1 + SIZE * 4);
  raw[rowStart] = 0;
  for (let px = 0; px < SIZE; px++) {
    let plateHits = 0;
    let barHits = 0;
    for (let sy = 0; sy < SS; sy++) {
      for (let sx = 0; sx < SS; sx++) {
        const fx = px + (sx + 0.5) / SS;
        const fy = py + (sy + 0.5) / SS;
        if (!insideRoundedRect(fx, fy, plate)) continue;
        plateHits++;
        const lx = (fx - offsetX) / scale;
        const ly = (fy - offsetY) / scale;
        if (BARS.some((bar) => insideRoundedRect(lx, ly, bar))) barHits++;
      }
    }
    const total = SS * SS;
    const alpha = Math.round((plateHits / total) * 255);
    // Blend bar coverage over the plate colour; alpha carries the plate edge.
    const mix = plateHits ? barHits / plateHits : 0;
    const o = rowStart + 1 + px * 4;
    for (let c = 0; c < 3; c++) {
      raw[o + c] = Math.round(BG[c] + (FG[c] - BG[c]) * mix);
    }
    raw[o + 3] = alpha;
  }
}

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const out = Buffer.alloc(8 + data.length + 4);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'ascii');
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0);
ihdr.writeUInt32BE(SIZE, 4);
ihdr[8] = 8; // bit depth
ihdr[9] = 6; // colour type: RGBA
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);

const buildDir = resolve(__dirname, '..', 'build');
mkdirSync(buildDir, { recursive: true });
const dest = join(buildDir, 'icon.png');
writeFileSync(dest, png);
console.log(`Wrote ${dest} (${SIZE}x${SIZE}, ${Math.round(png.length / 1024)} KB)`);
