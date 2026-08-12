#!/usr/bin/env node
// Zero-dependency static file server for src/. Shared by the bare-metal target
// (npm start) and by the Electron build, which runs it on 127.0.0.1 so the
// renderer gets a secure context — WebCodecs (VideoEncoder) and IndexedDB are
// both unavailable over file://.
//
// CommonJS on purpose: the Electron main process requires it straight out of
// the asar archive, where ESM loading is not guaranteed.
//
// Range requests matter here: the audio/video panels seek in media files.

const { createReadStream, statSync } = require('node:fs');
const { createServer } = require('node:http');
const { extname, join, normalize, resolve, sep } = require('node:path');

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.wav': 'audio/wav',
  '.mp3': 'audio/mpeg',
  '.ogg': 'audio/ogg',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.wasm': 'application/wasm',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
};

function send(res, status, body, headers = {}) {
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    ...headers,
  });
  res.end(body);
}

function startServer({ root, host = '127.0.0.1', port = 0 } = {}) {
  const rootDir = resolve(root);

  const server = createServer((req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return send(res, 405, 'Method not allowed', { allow: 'GET, HEAD' });
    }

    const url = new URL(req.url, 'http://localhost');
    let pathname;
    try {
      pathname = decodeURIComponent(url.pathname);
    } catch {
      return send(res, 400, 'Bad request');
    }
    if (pathname.endsWith('/')) pathname += 'index.html';

    // normalize() collapses ../ before we compare, so nothing outside rootDir
    // can be reached even with encoded traversal sequences.
    const filePath = join(rootDir, normalize(pathname));
    if (filePath !== rootDir && !filePath.startsWith(rootDir + sep)) {
      return send(res, 403, 'Forbidden');
    }

    let stat;
    try {
      stat = statSync(filePath);
      if (stat.isDirectory()) throw new Error('directory');
    } catch {
      return send(res, 404, 'Not found');
    }

    const ext = extname(filePath).toLowerCase();
    const headers = {
      'content-type': TYPES[ext] || 'application/octet-stream',
      'accept-ranges': 'bytes',
      // The HTML entry point must never be cached or a rebuild ships stale
      // script tags; everything else is safe to keep for a session.
      'cache-control': ext === '.html' ? 'no-cache' : 'public, max-age=3600',
      'x-content-type-options': 'nosniff',
    };

    const range = req.headers.range;
    if (range) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
      if (match) {
        const size = stat.size;
        let start = match[1] === '' ? null : Number(match[1]);
        let end = match[2] === '' ? null : Number(match[2]);
        if (start === null) {
          // Suffix form: "bytes=-500" means the last 500 bytes.
          start = Math.max(0, size - (end || 0));
          end = size - 1;
        } else {
          end = end === null ? size - 1 : Math.min(end, size - 1);
        }
        if (start > end || start >= size) {
          return send(res, 416, 'Range not satisfiable', {
            'content-range': `bytes */${size}`,
          });
        }
        res.writeHead(206, {
          ...headers,
          'content-range': `bytes ${start}-${end}/${size}`,
          'content-length': end - start + 1,
        });
        if (req.method === 'HEAD') return res.end();
        return createReadStream(filePath, { start, end }).pipe(res);
      }
    }

    res.writeHead(200, { ...headers, 'content-length': stat.size });
    if (req.method === 'HEAD') return res.end();
    createReadStream(filePath).pipe(res);
  });

  return new Promise((ok, fail) => {
    server.on('error', fail);
    server.listen(port, host, () => {
      const bound = server.address().port;
      ok({ server, port: bound, url: `http://${host}:${bound}/` });
    });
  });
}

module.exports = { startServer };

// Direct invocation: npm start / node scripts/server.cjs
if (require.main === module) {
  const root = resolve(__dirname, '..', 'src');
  const host = process.env.HOST || '127.0.0.1';
  const port = Number(process.env.PORT || 8080);
  startServer({ root, host, port }).then(({ url }) => {
    console.log(`Motionity serving ${root}`);
    console.log(`  ${url}`);
    if (host !== '127.0.0.1' && host !== 'localhost') {
      console.log(
        `\nNOTE: browsers expose WebCodecs and IndexedDB only in a secure\n` +
          `context. Reached over plain http:// from another machine this\n` +
          `disables the fast exporter and project saving. Use TLS for LAN or\n` +
          `remote access.`
      );
    }
  });
}
