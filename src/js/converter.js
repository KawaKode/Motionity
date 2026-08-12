// MP4/GIF export transcodes the captured WebM with ffmpeg.wasm.
//
// Everything is served from vendor/ffmpeg/, vendored out of node_modules by
// `npm run vendor` and pinned by package-lock.json. There is deliberately no
// CDN fallback: the asm.js build this replaced was fetched from a public
// archive.org mirror with no integrity check, so a changed object there would
// have run in the page unnoticed.
//
// The core is the single-threaded build. The default multi-threaded one needs
// SharedArrayBuffer, which requires COOP/COEP isolation, which would break the
// Pixabay, Unsplash and Google Fonts requests the editor makes.

var FFMPEG_DIR = 'vendor/ffmpeg/';
var FFMPEG_CORE = FFMPEG_DIR + 'ffmpeg-core.js';
var FFMPEG_WASM = FFMPEG_DIR + 'ffmpeg-core.wasm';
var FFMPEG_WORKER = FFMPEG_DIR + 'ffmpeg-core.worker.js';

// One instance per conversion, deliberately not cached. The single-threaded
// core's `main` calls exit() when the command finishes, which tears the wasm
// runtime down: a second run on the same instance dies with "Program terminated
// with exit(0)". Reloading costs about 110ms and returns the 23 MB heap in
// between, so this is cheaper than it looks.
var ffmpegBusy = false;

function ffmpegAvailable() {
  return typeof FFmpeg !== 'undefined' && typeof FFmpeg.createFFmpeg === 'function';
}

// The loader resolves the core through `new URL(corePath, import.meta.url)`,
// which points at the bundle rather than the page once it is minified. Passing
// all three paths absolute skips that resolution entirely.
function absolute(path) {
  return new URL(path, location.href).href;
}

async function loadFfmpeg() {
  if (!ffmpegAvailable()) {
    throw new Error(
      'the ffmpeg.wasm loader is missing — run "npm run vendor" to populate src/vendor/'
    );
  }

  // A build made with WITH_FFMPEG=0 ships the loader but not the 23 MB core,
  // so check before paying for the load and report it as a build choice
  // rather than a failure.
  var head = await fetch(FFMPEG_WASM, { method: 'HEAD' }).catch(function () {
    return null;
  });
  if (!head || !head.ok) {
    throw new Error(
      'this build ships without the ffmpeg core (WITH_FFMPEG=0), so MP4 and GIF ' +
        'export are unavailable. WEBM export always works.'
    );
  }

  var instance = FFmpeg.createFFmpeg({
    corePath: absolute(FFMPEG_CORE),
    wasmPath: absolute(FFMPEG_WASM),
    workerPath: absolute(FFMPEG_WORKER),
    // The loader defaults to the entry point of the multi-threaded core; the
    // single-threaded one exports plain `main`. Without this, load() gets as
    // far as compiling the 23 MB wasm and then aborts with
    // "Cannot call unknown function proxy_main".
    mainName: 'main',
    log: false,
    logger: function (entry) {
      if (entry.type === 'fferr') console.debug('[ffmpeg]', entry.message);
    },
    progress: function (entry) {
      if (typeof entry.ratio === 'number' && entry.ratio >= 0 && entry.ratio <= 1) {
        $('#download-real').html('Converting ' + Math.round(entry.ratio * 100) + '%');
      }
    },
  });
  await instance.load();
  return instance;
}

// The recording was made at this rate, so the transcode has to keep it: a
// different -r would duplicate or drop frames and drift the timing.
function conversionArgs(setting, fps) {
  if (setting === 'gif') {
    return ['-i', 'input.webm', '-r', String(fps), 'output.gif'];
  }
  // libx264 rather than the mpeg4 the asm.js path used: same core, far better
  // quality per byte, and it plays in Safari and QuickTime. yuv420p is what
  // makes that true — x264 defaults to yuv444p here, which they refuse.
  return [
    '-i', 'input.webm',
    '-c:v', 'libx264',
    '-preset', 'ultrafast',
    '-crf', '23',
    '-pix_fmt', 'yuv420p',
    '-r', String(fps),
    '-c:a', 'aac',
    '-b:a', '192k',
    'output.mp4',
  ];
}

async function convertStreams(videoBlob, setting) {
  var outputName = setting === 'gif' ? 'output.gif' : 'output.mp4';
  var mimeType = setting === 'gif' ? 'image/gif' : 'video/mp4';

  function convertFailed(reason) {
    console.error('Conversion failed: ' + reason);
    alert(
      'Sorry, the ' +
        setting.toUpperCase() +
        ' conversion failed. The WEBM format is always available.\n\n' +
        reason
    );
    resetRecordingUI();
  }

  if (setting !== 'gif' && setting !== 'mp4') {
    convertFailed('unknown output format "' + setting + '"');
    return;
  }
  if (ffmpegBusy) {
    convertFailed('a conversion is already running — wait for it to finish');
    return;
  }

  ffmpegBusy = true;
  var ffmpeg = null;
  try {
    $('#download-real').html('Loading converter...');
    ffmpeg = await loadFfmpeg();

    ffmpeg.FS('writeFile', 'input.webm', new Uint8Array(await videoBlob.arrayBuffer()));
    $('#download-real').html('Converting 0%');
    await ffmpeg.run.apply(ffmpeg, conversionArgs(setting, getExportFramerate()));

    var data = ffmpeg.FS('readFile', outputName);
    if (!data || !data.length) {
      convertFailed('the encoder returned no data');
      return;
    }
    // Copy out of the wasm heap before unlinking: the view would otherwise be
    // backed by memory ffmpeg is free to reuse.
    PostBlob(new File([data.slice()], 'video.' + setting, { type: mimeType }));
  } catch (err) {
    convertFailed((err && err.message) || String(err));
  } finally {
    // Tear the instance down either way. After a success the runtime has
    // already exited and is unusable; after a failure the loader's internal
    // "running" flag would otherwise stay set and every later conversion would
    // fail with "can only run one command at a time" until a page reload.
    // Dropping the reference also returns the 23 MB heap and whatever MEMFS
    // still holds, which for a long export is most of the memory in play.
    if (ffmpeg) {
      try {
        ffmpeg.exit();
      } catch (e) {
        /* already torn down by its own exit(0) */
      }
    }
    ffmpegBusy = false;
  }
}

function PostBlob(blob) {
  var url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.style.display = 'none';
  a.href = url;
  a.download = blob.name || 'video';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  window.setTimeout(function () {
    URL.revokeObjectURL(url);
  }, 60000);
  resetRecordingUI();
}
