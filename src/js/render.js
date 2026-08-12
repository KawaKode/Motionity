// Frame-accurate offline renderer.
//
// The original export path captured the canvas with MediaRecorder in real
// time, so anything the browser could not draw at 60fps was simply dropped and
// video layers were sampled wherever they happened to be. This renders one
// frame at a time with no clock attached: every frame is drawn at the frame
// rate picked in the download modal, every video layer is seeked to the exact
// frame time, and the audio is mixed offline.
//
// Needs WebCodecs (Chrome/Edge). record() falls back to the real-time path
// when this is unavailable or fails.

// The muxer can only close a cluster on a video keyframe, and a cluster may
// not span more than ~32s (block timecodes are a signed 16 bit offset), so
// keyframes have to stay frequent.
const RENDER_KEYFRAME_INTERVAL = 2; // seconds
// A seek that never completes must not hang the whole export
const RENDER_MAX_SEEK_WAIT = 2000;

// recordAnimate() drives video playback in real time; while rendering offline
// the frames are seeked explicitly instead.
var offlinerender = false;

function frameAccurateSupported() {
  return (
    typeof VideoEncoder !== 'undefined' &&
    typeof VideoFrame !== 'undefined' &&
    typeof WebMWriter !== 'undefined' &&
    typeof OfflineAudioContext !== 'undefined'
  );
}

function renderProgress(text) {
  $('#download-real').html(text);
}

// ---------------------------------------------------------------------------
// Media positioning
// ---------------------------------------------------------------------------

// Put every time-based layer at exactly `time` and wait until it is actually
// showing that frame. A plain currentTime assignment is asynchronous - drawing
// before 'seeked' captures the previous frame.
async function seekMediaForFrame(time) {
  const waits = [];
  objects.forEach(function (object) {
    const obj = canvasrecord.getItemById(object.id);
    const p_keyframe = p_keyframes.find((x) => x.id == object.id);
    if (!obj || !p_keyframe) {
      return;
    }

    if (obj.type == 'lottie') {
      obj.goToSeconds(time);
      return;
    }

    if (obj.get('assetType') != 'video') {
      return;
    }

    const element = $(obj.getElement())[0];
    if (!element) {
      return;
    }
    element.pause();

    const visible =
      time >= p_keyframe.trimstart + p_keyframe.start &&
      time <= p_keyframe.end;
    obj.set('visible', visible);
    if (!visible) {
      return;
    }

    var target =
      (time - p_keyframe.start + p_keyframe.trimstart) / 1000;
    if (element.duration) {
      target = Math.min(target, Math.max(0, element.duration - 0.001));
    }
    target = Math.max(0, target);
    if (Math.abs(element.currentTime - target) < 0.0005) {
      return;
    }

    waits.push(
      new Promise(function (resolve) {
        var settled = false;
        function finish() {
          if (settled) {
            return;
          }
          settled = true;
          element.removeEventListener('seeked', finish);
          element.removeEventListener('error', finish);
          resolve();
        }
        element.addEventListener('seeked', finish);
        element.addEventListener('error', finish);
        // A stuck seek must not hang the whole export
        window.setTimeout(finish, RENDER_MAX_SEEK_WAIT);
        try {
          element.currentTime = target;
        } catch (e) {
          finish();
        }
      })
    );
  });
  await Promise.all(waits);
}

// ---------------------------------------------------------------------------
// Audio
// ---------------------------------------------------------------------------

// Every sound in the project, with where it sits on the timeline
function collectAudioSources() {
  const sources = [];
  objects.forEach(function (object) {
    const obj = canvasrecord.getItemById(object.id);
    const p_keyframe = p_keyframes.find((x) => x.id == object.id);
    if (!obj || !p_keyframe) {
      return;
    }
    if (obj.get('assetType') == 'audio' && obj.get('audioSrc')) {
      sources.push({
        src: obj.get('audioSrc'),
        start: p_keyframe.start,
        end: p_keyframe.end,
        trimstart: p_keyframe.trimstart,
        volume: obj.get('volume'),
      });
    } else if (obj.get('assetType') == 'video' && obj.get('source')) {
      sources.push({
        src: obj.get('source'),
        start: p_keyframe.start,
        end: p_keyframe.end,
        trimstart: p_keyframe.trimstart,
        volume: 1,
      });
    }
  });
  if (background_audio != false && background_audio.src) {
    sources.push({
      src: background_audio.src,
      start: 0,
      end: duration,
      trimstart: 0,
      volume: 1,
    });
  }
  return sources;
}

// Mix the whole timeline in one pass. OfflineAudioContext renders faster than
// real time and is sample-accurate, unlike routing live elements into a
// MediaStream.
async function renderAudioBuffer() {
  const sources = collectAudioSources();
  if (sources.length == 0) {
    return null;
  }

  const sampleRate = 48000;
  const frames = Math.ceil((duration / 1000) * sampleRate);
  if (!(frames > 0)) {
    return null;
  }
  const offline = new OfflineAudioContext(2, frames, sampleRate);

  const decoded = [];
  for (const source of sources) {
    try {
      const response = await fetch(source.src);
      const bytes = await response.arrayBuffer();
      const buffer = await offline.decodeAudioData(bytes);
      decoded.push({ source: source, buffer: buffer });
    } catch (e) {
      // Silent video, unsupported container, or an unreachable asset
      console.warn('Skipping audio source', e);
    }
  }
  if (decoded.length == 0) {
    return null;
  }

  decoded.forEach(function (item) {
    const node = offline.createBufferSource();
    node.buffer = item.buffer;
    const gain = offline.createGain();
    gain.gain.value =
      typeof item.source.volume == 'number' ? item.source.volume : 1;
    node.connect(gain);
    gain.connect(offline.destination);

    const when = Math.max(0, item.source.start / 1000);
    const offset = Math.max(0, item.source.trimstart / 1000);
    const length = Math.max(
      0,
      (item.source.end - item.source.start) / 1000
    );
    if (length > 0 && offset < item.buffer.duration) {
      node.start(when, offset, length);
    }
  });

  return await offline.startRendering();
}

// Matroska needs the Opus identification header as CodecPrivate
function buildOpusHead(channels, sampleRate) {
  const head = new Uint8Array(19);
  const view = new DataView(head.buffer);
  head.set([0x4f, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64], 0); // "OpusHead"
  head[8] = 1; // version
  head[9] = channels;
  view.setUint16(10, 3840, true); // pre-skip
  view.setUint32(12, sampleRate, true);
  view.setUint16(16, 0, true); // output gain
  head[18] = 0; // channel mapping family
  return head;
}

async function encodeAudioBuffer(audioBuffer) {
  const channels = Math.min(2, audioBuffer.numberOfChannels);
  const sampleRate = audioBuffer.sampleRate;
  const config = {
    codec: 'opus',
    sampleRate: sampleRate,
    numberOfChannels: channels,
    bitrate: 128000,
  };
  if (typeof AudioEncoder === 'undefined') {
    return null;
  }
  const support = await AudioEncoder.isConfigSupported(config);
  if (!support || !support.supported) {
    return null;
  }

  const chunks = [];
  var failed = false;
  const encoder = new AudioEncoder({
    output: function (chunk) {
      chunks.push(chunk);
    },
    error: function (e) {
      failed = true;
      console.error('Audio encoding failed', e);
    },
  });
  encoder.configure(config);

  const sliceFrames = Math.round(sampleRate / 10); // 100ms
  const planes = [];
  for (var c = 0; c < channels; c++) {
    planes.push(audioBuffer.getChannelData(c));
  }

  for (
    var offset = 0;
    offset < audioBuffer.length && !failed;
    offset += sliceFrames
  ) {
    const count = Math.min(sliceFrames, audioBuffer.length - offset);
    const planar = new Float32Array(count * channels);
    for (var ch = 0; ch < channels; ch++) {
      planar.set(
        planes[ch].subarray(offset, offset + count),
        ch * count
      );
    }
    const data = new AudioData({
      format: 'f32-planar',
      sampleRate: sampleRate,
      numberOfFrames: count,
      numberOfChannels: channels,
      timestamp: Math.round((offset / sampleRate) * 1e6),
      data: planar,
    });
    encoder.encode(data);
    data.close();
  }

  await encoder.flush();
  encoder.close();
  if (failed || chunks.length == 0) {
    return null;
  }
  return {
    chunks: chunks,
    sampleRate: sampleRate,
    channels: channels,
    codecPrivate: buildOpusHead(channels, sampleRate),
  };
}

// ---------------------------------------------------------------------------
// Video
// ---------------------------------------------------------------------------

async function pickVideoCodec(width, height, fps) {
  const candidates = [
    { codec: 'vp09.00.10.08', name: 'VP9' },
    { codec: 'vp8', name: 'VP8' },
  ];
  for (const candidate of candidates) {
    const config = {
      codec: candidate.codec,
      width: width,
      height: height,
      bitrate: 8000000,
      framerate: fps,
    };
    try {
      const support = await VideoEncoder.isConfigSupported(config);
      if (support && support.supported) {
        return { config: config, name: candidate.name };
      }
    } catch (e) {
      // try the next one
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

// Confirm the muxed file is actually decodable before handing it to the user.
// The muxer is hand-rolled, so a silent failure here would otherwise reach
// the user as a file that will not play.
function verifyRenderedBlob(blob) {
  return new Promise(function (resolve) {
    const element = document.createElement('video');
    const url = URL.createObjectURL(blob);
    var settled = false;
    function finish(ok) {
      if (settled) {
        return;
      }
      settled = true;
      URL.revokeObjectURL(url);
      element.removeAttribute('src');
      resolve(ok);
    }
    element.onloadedmetadata = function () {
      finish(element.videoWidth > 0 && element.videoHeight > 0);
    };
    element.onerror = function () {
      finish(false);
    };
    window.setTimeout(function () {
      finish(false);
    }, 5000);
    element.src = url;
  });
}

// Returns a WebM Blob, or null to tell the caller to use the real-time path
async function renderFrameAccurate() {
  const canvasElement = document.getElementById('canvasrecord');
  const width = canvasElement.width;
  const height = canvasElement.height;
  if (!(width > 0 && height > 0)) {
    return null;
  }

  const fps = getExportFramerate();
  const selected = await pickVideoCodec(width, height, fps);
  if (!selected) {
    console.warn('No supported WebCodecs video configuration');
    return null;
  }

  offlinerender = true;
  var encoder = null;
  try {
    renderProgress('Mixing audio...');
    var audio = null;
    try {
      const audioBuffer = await renderAudioBuffer();
      if (audioBuffer) {
        audio = await encodeAudioBuffer(audioBuffer);
      }
    } catch (e) {
      console.warn('Rendering without audio', e);
      audio = null;
    }

    const writer = new WebMWriter({
      codec: selected.name,
      width: width,
      height: height,
      audio: audio
        ? {
            sampleRate: audio.sampleRate,
            channels: audio.channels,
            codecPrivate: audio.codecPrivate,
          }
        : null,
    });

    const videoChunks = [];
    var encoderFailed = false;
    encoder = new VideoEncoder({
      output: function (chunk) {
        videoChunks.push(chunk);
      },
      error: function (e) {
        encoderFailed = true;
        console.error('Video encoding failed', e);
      },
    });
    encoder.configure(selected.config);

    const totalFrames = Math.max(
      1,
      Math.round((duration / 1000) * fps)
    );
    const frameDuration = 1e6 / fps;
    const keyframeEvery = Math.max(
      1,
      Math.round(fps * RENDER_KEYFRAME_INTERVAL)
    );

    for (var i = 0; i < totalFrames; i++) {
      if (encoderFailed) {
        break;
      }
      const time = (i / fps) * 1000;

      await seekMediaForFrame(time);
      await recordAnimate(time);
      canvasrecord.renderAll();

      const frame = new VideoFrame(canvasElement, {
        timestamp: Math.round(i * frameDuration),
        duration: Math.round(frameDuration),
      });
      encoder.encode(frame, { keyFrame: i % keyframeEvery == 0 });
      frame.close();

      // Keep the encoder queue short so memory stays bounded
      while (encoder.encodeQueueSize > 8 && !encoderFailed) {
        await new Promise(function (resolve) {
          window.setTimeout(resolve, 4);
        });
      }

      if (i % 5 == 0) {
        renderProgress(
          'Rendering ' +
            Math.round(((i + 1) / totalFrames) * 100) +
            '%'
        );
      }
    }

    await encoder.flush();
    encoder.close();
    encoder = null;
    if (encoderFailed || videoChunks.length == 0) {
      return null;
    }

    renderProgress('Muxing...');
    // Interleave both tracks in timestamp order: a cluster's blocks have to
    // be ordered, and this avoids threading the two producers together.
    const all = [];
    videoChunks.forEach(function (chunk) {
      all.push({ chunk: chunk, track: 1 });
    });
    if (audio) {
      audio.chunks.forEach(function (chunk) {
        all.push({ chunk: chunk, track: 2 });
      });
    }
    all.sort(function (a, b) {
      if (a.chunk.timestamp == b.chunk.timestamp) {
        return a.track - b.track;
      }
      return a.chunk.timestamp - b.chunk.timestamp;
    });
    all.forEach(function (item) {
      writer.addFrame(item.chunk, item.track);
    });

    const blob = await writer.complete();
    if (!blob || blob.size == 0) {
      return null;
    }
    if (!(await verifyRenderedBlob(blob))) {
      console.warn(
        'Rendered file failed verification, using the real-time encoder'
      );
      return null;
    }
    return blob;
  } catch (e) {
    console.error('Frame-accurate render failed', e);
    return null;
  } finally {
    offlinerender = false;
    if (encoder && encoder.state != 'closed') {
      try {
        encoder.close();
      } catch (e) {
        // already torn down
      }
    }
  }
}
