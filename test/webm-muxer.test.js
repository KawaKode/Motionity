// Exercise the extended WebM muxer without a browser and validate the EBML it
// produces. Feeds fake encoded chunks, then parses the resulting file.
const fs = require('fs');
const vm = require('vm');

const code = fs.readFileSync(
  require('path').join(__dirname, '..', 'src', 'js', 'webm-writer2.js'),
  'utf8'
);

const sandbox = { Blob, console };
sandbox.self = sandbox;
vm.createContext(sandbox);
// `module` must stay undefined so the browser branch runs
vm.runInContext(code, sandbox);

const WebMWriter = sandbox.WebMWriter;
if (!WebMWriter) throw new Error('WebMWriter not exported');

class EncodedVideoChunk {
  constructor(o) {
    this.timestamp = o.timestamp;
    this.type = o.type;
    this._data = o.data;
    this.byteLength = o.data.length;
  }
  copyTo(dst) {
    dst.set(this._data);
  }
}
class EncodedAudioChunk {
  constructor(o) {
    this.timestamp = o.timestamp;
    this.type = o.type;
    this._data = o.data;
    this.byteLength = o.data.length;
  }
  copyTo(dst) {
    dst.set(this._data);
  }
}

function opusHead(channels, sampleRate) {
  const head = new Uint8Array(19);
  const view = new DataView(head.buffer);
  head.set([0x4f, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64], 0);
  head[8] = 1;
  head[9] = channels;
  view.setUint16(10, 3840, true);
  view.setUint32(12, sampleRate, true);
  view.setUint16(16, 0, true);
  head[18] = 0;
  return head;
}

// ---- EBML parser -----------------------------------------------------------
function readVarInt(buf, pos, stripMarker) {
  const first = buf[pos];
  if (first === 0) throw new Error('invalid varint at ' + pos);
  let width = 1;
  let mask = 0x80;
  while (!(first & mask)) {
    mask >>= 1;
    width++;
  }
  let value = stripMarker ? first & (mask - 1) : first;
  let unknown = stripMarker && (first & (mask - 1)) === mask - 1;
  for (let i = 1; i < width; i++) {
    value = value * 256 + buf[pos + i];
    if (buf[pos + i] !== 0xff) unknown = false;
  }
  return { value, width, unknown };
}

function parse(buf, start, end, depth, out) {
  let pos = start;
  while (pos < end) {
    const id = readVarInt(buf, pos, false);
    const idBytes = buf.slice(pos, pos + id.width);
    let idHex = 0;
    for (const b of idBytes) idHex = idHex * 256 + b;
    pos += id.width;
    const size = readVarInt(buf, pos, true);
    pos += size.width;
    const dataStart = pos;
    const dataEnd = size.unknown ? end : Math.min(dataStart + size.value, end);
    out.push({ id: idHex, depth, dataStart, dataEnd });
    const MASTER = [
      0x1a45dfa3, 0x18538067, 0x1654ae6b, 0xae, 0x1f43b675, 0x1549a966,
      0x114d9b74, 0x4dbb, 0xe0, 0xe1, 0x1c53bb6b, 0xbb, 0xb7,
    ];
    if (MASTER.includes(idHex)) parse(buf, dataStart, dataEnd, depth + 1, out);
    pos = dataEnd;
    if (dataEnd <= dataStart && size.value === 0) continue;
  }
}

function uintAt(buf, s, e) {
  let v = 0;
  for (let i = s; i < e; i++) v = v * 256 + buf[i];
  return v;
}
function strAt(buf, s, e) {
  return Buffer.from(buf.slice(s, e)).toString('ascii').replace(/\0+$/, '');
}

async function run(withAudio) {
  const writer = new WebMWriter({
    codec: 'VP9',
    width: 640,
    height: 480,
    audio: withAudio
      ? { sampleRate: 48000, channels: 2, codecPrivate: opusHead(2, 48000) }
      : null,
  });

  const FPS = 30;
  const SECONDS = 75;
  const items = [];
  for (let i = 0; i < FPS * SECONDS; i++) {
    items.push({
      track: 1,
      chunk: new EncodedVideoChunk({
        timestamp: Math.round((i / FPS) * 1e6),
        type: i % (FPS * 2) === 0 ? 'key' : 'delta',
        data: new Uint8Array(120).fill(i & 0xff),
      }),
    });
  }
  if (withAudio) {
    for (let i = 0; i < SECONDS * 10; i++) {
      items.push({
        track: 2,
        chunk: new EncodedAudioChunk({
          timestamp: Math.round(i * 0.1 * 1e6),
          type: 'key',
          data: new Uint8Array(40).fill(0x55),
        }),
      });
    }
  }
  items.sort((a, b) =>
    a.chunk.timestamp === b.chunk.timestamp
      ? a.track - b.track
      : a.chunk.timestamp - b.chunk.timestamp
  );
  items.forEach((it) => writer.addFrame(it.chunk, it.track));

  const blob = await writer.complete();
  const buf = new Uint8Array(await blob.arrayBuffer());

  const els = [];
  parse(buf, 0, buf.length, 0, els);

  const label = withAudio ? 'video+audio' : 'video only';
  const problems = [];

  if (!els.some((e) => e.id === 0x1a45dfa3)) problems.push('no EBML header');
  if (!els.some((e) => e.id === 0x18538067)) problems.push('no Segment');

  const trackEntries = els.filter((e) => e.id === 0xae);
  const expectedTracks = withAudio ? 2 : 1;
  if (trackEntries.length !== expectedTracks)
    problems.push(`expected ${expectedTracks} TrackEntry, got ${trackEntries.length}`);

  const codecIds = els
    .filter((e) => e.id === 0x86)
    .map((e) => strAt(buf, e.dataStart, e.dataEnd));
  if (!codecIds.includes('V_VP9')) problems.push('missing V_VP9, got ' + codecIds);
  if (withAudio && !codecIds.includes('A_OPUS'))
    problems.push('missing A_OPUS, got ' + codecIds);

  const trackTypes = els
    .filter((e) => e.id === 0x83)
    .map((e) => uintAt(buf, e.dataStart, e.dataEnd));
  if (!trackTypes.includes(1)) problems.push('no video TrackType');
  if (withAudio && !trackTypes.includes(2)) problems.push('no audio TrackType');

  if (withAudio) {
    const priv = els.find((e) => e.id === 0x63a2);
    if (!priv) problems.push('no CodecPrivate');
    else {
      if (priv.dataEnd - priv.dataStart !== 19)
        problems.push('CodecPrivate is not 19 bytes');
      if (strAt(buf, priv.dataStart, priv.dataStart + 8) !== 'OpusHead')
        problems.push('CodecPrivate is not OpusHead');
    }
  }

  const clusters = els.filter((e) => e.id === 0x1f43b675);
  if (clusters.length < 2)
    problems.push(`expected multiple clusters over ${SECONDS}s, got ${clusters.length}`);

  // Every SimpleBlock: track number valid, timecode inside signed 16 bit
  const blocks = els.filter((e) => e.id === 0xa3);
  if (blocks.length !== items.length)
    problems.push(`expected ${items.length} blocks, got ${blocks.length}`);
  const seenTracks = new Set();
  let badTimecode = 0;
  for (const b of blocks) {
    const tn = readVarInt(buf, b.dataStart, true);
    seenTracks.add(tn.value);
    const tc = (buf[b.dataStart + tn.width] << 8) | buf[b.dataStart + tn.width + 1];
    const signed = tc > 32767 ? tc - 65536 : tc;
    if (signed < 0 || signed > 32767) badTimecode++;
  }
  if (badTimecode) problems.push(badTimecode + ' block timecodes out of range');
  const expectTrackSet = withAudio ? [1, 2] : [1];
  for (const t of expectTrackSet)
    if (!seenTracks.has(t)) problems.push('no blocks for track ' + t);
  for (const t of seenTracks)
    if (!expectTrackSet.includes(t)) problems.push('unexpected track ' + t);

  // Reconstruct absolute times: cluster timecode + block timecode must give
  // back exactly the timestamps that went in, in order.
  const rebuilt = [];
  let lastClusterTime = -1;
  for (const c of clusters) {
    const tcEl = els.find(
      (e) => e.id === 0xe7 && e.dataStart > c.dataStart && e.dataEnd <= c.dataEnd
    );
    if (!tcEl) {
      problems.push('cluster without Timecode');
      continue;
    }
    const clusterTime = uintAt(buf, tcEl.dataStart, tcEl.dataEnd);
    if (clusterTime < lastClusterTime) problems.push('cluster timecodes go backwards');
    lastClusterTime = clusterTime;
    const inner = blocks.filter(
      (b) => b.dataStart > c.dataStart && b.dataEnd <= c.dataEnd
    );
    if (inner.length === 0) problems.push('empty cluster');
    for (const b of inner) {
      const tn = readVarInt(buf, b.dataStart, true);
      const raw = (buf[b.dataStart + tn.width] << 8) | buf[b.dataStart + tn.width + 1];
      const rel = raw > 32767 ? raw - 65536 : raw;
      if (rel < 0) problems.push('negative block timecode in cluster');
      rebuilt.push({ track: tn.value, ms: clusterTime + rel });
    }
  }
  const expected = items.map((it) => ({
    track: it.track,
    ms: Math.round(it.chunk.timestamp / 1000),
  }));
  if (rebuilt.length !== expected.length) {
    problems.push('block count mismatch on rebuild');
  } else {
    let drift = 0;
    for (let i = 0; i < expected.length; i++) {
      if (rebuilt[i].track !== expected[i].track) {
        problems.push('track order changed at block ' + i);
        break;
      }
      drift = Math.max(drift, Math.abs(rebuilt[i].ms - expected[i].ms));
    }
    if (drift > 1) problems.push('timestamp drift of ' + drift + 'ms');
  }

  const durationEl = els.find((e) => e.id === 0x4489);
  if (!durationEl) problems.push('no Duration');
  else {
    const dv = new DataView(buf.buffer, buf.byteOffset + durationEl.dataStart, 8);
    const d = dv.getFloat64(0);
    if (!(d > 0)) problems.push('Duration is ' + d);
    else if (Math.abs(d - (SECONDS - 1 / FPS) * 1000) > 200)
      problems.push('Duration ' + d + 'ms is not ~' + SECONDS * 1000);
  }

  console.log(
    `[${label}] ${buf.length} bytes, ${clusters.length} clusters, ` +
      `${blocks.length} blocks, tracks=${[...seenTracks].join(',')}`
  );
  if (problems.length) {
    console.log('  FAIL:');
    problems.forEach((p) => console.log('   - ' + p));
    return false;
  }
  console.log('  OK');
  return true;
}

(async () => {
  const a = await run(false);
  const b = await run(true);
  process.exit(a && b ? 0 : 1);
})();
