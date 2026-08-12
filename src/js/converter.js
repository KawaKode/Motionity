// MP4/GIF export transcodes the captured WebM with an asm.js build of ffmpeg.
// Packaged builds ship it locally (npm run vendor); a plain checkout falls back
// to the public mirror, which needs network access.
var FFMPEG_ASM_LOCAL = 'vendor/ffmpeg_asm.js';
var FFMPEG_ASM_REMOTE = 'https://archive.org/download/ffmpeg_asm/ffmpeg_asm.js';
var ffmpegAsmUrlPromise = null;

// The worker is built from a blob, so importScripts() needs an absolute URL.
function resolveFfmpegAsmUrl() {
  if (!ffmpegAsmUrlPromise) {
    ffmpegAsmUrlPromise = fetch(FFMPEG_ASM_LOCAL, { method: 'HEAD' })
      .then(function (res) {
        // A catch-all/SPA route answers 200 with HTML; that is not the script.
        var type = res.headers.get('content-type') || '';
        var local = res.ok && type.indexOf('text/html') === -1;
        return local
          ? new URL(FFMPEG_ASM_LOCAL, location.href).href
          : FFMPEG_ASM_REMOTE;
      })
      .catch(function () {
        return FFMPEG_ASM_REMOTE;
      });
  }
  return ffmpegAsmUrlPromise;
}

function processInWebWorker(workerPath) {
  var blob = URL.createObjectURL(
    new Blob(
      [
        'importScripts("' +
          workerPath +
          '");var now = Date.now;function print(text) {postMessage({"type" : "stdout","data" : text});};onmessage = function(event) {var message = event.data;if (message.type === "command") {var Module = {print: print,printErr: print,files: message.files || [],arguments: message.arguments || [],TOTAL_MEMORY: message.TOTAL_MEMORY||536870912  || false};postMessage({"type" : "start","data" : Module.arguments.join(" ")});postMessage({"type" : "stdout","data" : "Received command: " +Module.arguments.join(" ") +((Module.TOTAL_MEMORY ) ? ".  Processing with " + Module.TOTAL_MEMORY + " bits." : "")});var time = now();var result = ffmpeg_run(Module);var totalTime = now() - time;postMessage({"type" : "stdout","data" : "Finished processing (took " + totalTime + "ms)"});postMessage({"type" : "done","data" : result,"time" : totalTime});}};postMessage({"type" : "ready"});',
      ],
      {
        type: 'application/javascript',
      }
    )
  );

  var worker = new Worker(blob);
  URL.revokeObjectURL(blob);
  return worker;
}

var worker;
// The worker is created once and reused, so its "ready" handshake only ever
// arrives for the first conversion. Remember it across calls.
var workerIsReady = false;

async function convertStreams(videoBlob, setting) {
  var aab;
  var buffersReady = false;
  var posted = false;

  function convertFailed(reason) {
    console.error('Conversion failed: ' + reason);
    alert(
      'Sorry, the ' +
        setting.toUpperCase() +
        ' conversion failed. The WEBM format is always available.'
    );
    resetRecordingUI();
  }

  var fileReader = new FileReader();
  fileReader.onload = function () {
    aab = this.result;
    buffersReady = true;
    if (workerIsReady) postMessage();
  };
  fileReader.onerror = function () {
    convertFailed('could not read the recorded video');
  };
  fileReader.readAsArrayBuffer(videoBlob);

  if (!worker) {
    // Safe to await here: workerIsReady is still false, so the FileReader
    // callback cannot post a command before the worker exists.
    worker = processInWebWorker(await resolveFfmpegAsmUrl());
  }
  worker.onerror = function (e) {
    convertFailed(e.message || 'worker error');
  };
  worker.onmessage = function (event) {
    var message = event.data;
    if (message.type == 'ready') {
      workerIsReady = true;
      if (buffersReady) postMessage();
    } else if (message.type == 'done') {
      var result = message.data && message.data[0];
      if (!result || !result.data) {
        convertFailed('the encoder returned no data');
        return;
      }
      if (setting == 'gif') {
        var blob = new File([result.data], 'video.gif', {
          type: 'image/gif',
        });
        PostBlob(blob);
      } else if (setting == 'mp4') {
        var blob = new File([result.data], 'video.mp4', {
          type: 'video/mp4',
        });
        PostBlob(blob);
      }
    }
  };
  var postMessage = function () {
    if (posted) return;
    posted = true;
    // The recording was made at this rate, so the transcode has to keep it:
    // a fixed -r would duplicate or drop frames and drift the timing.
    const fps = getExportFramerate();
    if (setting == 'gif') {
      worker.postMessage({
        type: 'command',
        arguments: ('-i video.webm -r ' + fps + ' output-10.gif').split(
          ' '
        ),
        files: [
          {
            data: new Uint8Array(aab),
            name: 'video.webm',
          },
        ],
      });
    } else if (setting == 'mp4') {
      worker.postMessage({
        type: 'command',
        arguments: (
          '-i video.webm -c:v mpeg4 -b:v 6400k -r ' +
          fps +
          ' -strict experimental output.mp4'
        ).split(' '),
        files: [
          {
            data: new Uint8Array(aab),
            name: 'video.webm',
          },
        ],
      });
    }
  };
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
