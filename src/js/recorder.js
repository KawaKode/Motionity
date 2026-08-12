// Everything the current export needs to tear down when it finishes
var exportAudio = null;

// Route every sound source of the project into a single destination node.
//
// This has to be one shared AudioContext with one destination:
//   - MediaRecorder only records the first audio track of a stream, so
//     adding one track per source silently dropped all but one of them,
//   - a context per source was never closed, and browsers cap how many a
//     page may hold.
function buildExportAudio(stream) {
  const ctx = new AudioContext();
  const destination = ctx.createMediaStreamDestination();
  const elements = [];
  var connected = false;

  function connect(element) {
    try {
      ctx.createMediaElementSource(element).connect(destination);
      connected = true;
      return true;
    } catch (e) {
      // Already bound to another context, or tainted by CORS
      console.warn('Could not route audio for export', e);
      return false;
    }
  }

  objects.forEach(function (object) {
    const obj = canvasrecord.getItemById(object.id);
    const p_keyframe = p_keyframes.find((x) => x.id == object.id);
    if (!obj || !p_keyframe) {
      return;
    }
    if (obj.get('assetType') == 'video') {
      const element = $(obj.getElement())[0];
      if (element) {
        connect(element);
      }
    } else if (
      obj.get('assetType') == 'audio' &&
      obj.get('audioSrc')
    ) {
      // Audio layers used to be left out of the export entirely
      const element = new Audio(obj.get('audioSrc'));
      element.crossOrigin = 'anonymous';
      element.volume = obj.get('volume');
      if (connect(element)) {
        elements.push({
          element: element,
          start: p_keyframe.start,
          end: p_keyframe.end,
          trimstart: p_keyframe.trimstart,
        });
      }
    }
  });

  if (background_audio != false && connect(background_audio)) {
    elements.push({
      element: background_audio,
      start: 0,
      end: duration,
      trimstart: 0,
    });
  }

  if (connected) {
    stream.addTrack(destination.stream.getAudioTracks()[0]);
  }
  return { context: ctx, elements: elements, timers: [] };
}

// Start the scheduled audio layers relative to the start of the recording
function startExportAudio(audio) {
  if (!audio) {
    return;
  }
  audio.elements.forEach(function (item) {
    item.element.currentTime = item.trimstart / 1000;
    audio.timers.push(
      window.setTimeout(function () {
        item.element.play();
      }, Math.max(0, item.start))
    );
    audio.timers.push(
      window.setTimeout(function () {
        item.element.pause();
      }, Math.max(0, item.end))
    );
  });
}

function stopExportAudio(audio) {
  if (!audio) {
    return;
  }
  audio.timers.forEach(window.clearTimeout);
  audio.timers = [];
  audio.elements.forEach(function (item) {
    item.element.pause();
  });
  if (audio.context && audio.context.state != 'closed') {
    audio.context.close();
  }
}

// Record canvas
async function record() {
  // loadFromJSON clears the record canvas and revives the objects
  // asynchronously, so nothing may be drawn or captured until it resolves.
  await updateRecordCanvas();
  if ($('input[name=radio]:checked').val() == 'image') {
    recording = true;
    paused = true;
    await recordAnimate(currenttime);
    const dataURL = canvasrecord.toDataURL({
      format: 'png',
    });
    const link = document.createElement('a');
    link.download = 'image.png';
    link.href = dataURL;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    recording = false;
    updateRecordCanvas();
    return;
  }
  if (recording) {
    return;
  }

  recording = true;
  paused = true;
  await recordAnimate(0);
  $('#download-real').html('Rendering...');
  $('#download-real').addClass('downloading');

  // Preferred path: render every frame offline, with no clock attached, so
  // nothing is dropped and video layers land on the exact frame.
  if (frameAccurateSupported()) {
    const blob = await renderFrameAccurate();
    if (blob) {
      deliverRecording(blob);
      return;
    }
    console.warn('Falling back to the real-time encoder');
    $('#download-real').html('Rendering...');
    await updateRecordCanvas();
    await recordAnimate(0);
  }

  const fps = getExportFramerate();
  const aCtx = new AudioContext();

  // requestAnimationFrame is throttled in background tabs, an oscillator is
  // not, so the render keeps running while the tab is hidden.
  function audioTimerLoop(callback, frequency) {
    const freq = frequency / 1000;
    const silence = aCtx.createGain();
    silence.gain.value = 0;
    silence.connect(aCtx.destination);
    var stopped = false;
    var osc;
    function onOSCend() {
      if (stopped) {
        return;
      }
      osc = aCtx.createOscillator();
      osc.onended = onOSCend;
      osc.connect(silence);
      osc.start(0);
      osc.stop(aCtx.currentTime + freq);
      callback(aCtx.currentTime);
    }
    onOSCend();
    return function () {
      stopped = true;
      if (osc) {
        osc.onended = null;
      }
    };
  }

  const stream = document
    .getElementById('canvasrecord')
    .captureStream(fps);
  exportAudio = buildExportAudio(stream);

  const chunks = [];
  const recorder = new MediaRecorder(stream, {
    bitsPerSecond: 3200000,
  });
  recorder.ondataavailable = (e) => chunks.push(e.data);
  recorder.onerror = (e) => {
    console.error('Recording failed', e);
    stopAnim();
    stopExportAudio(exportAudio);
    exportAudio = null;
    aCtx.close();
    resetRecordingUI();
  };
  recorder.onstop = () => {
    stopAnim();
    stopExportAudio(exportAudio);
    exportAudio = null;
    stream.getTracks().forEach((track) => track.stop());
    aCtx.close();
    downloadRecording(chunks);
    console.log('Finished rendering');
  };

  // The capture is real time, so the animation clock is driven off the audio
  // clock and the recording is stopped once it has covered the timeline.
  var origin = null;
  var stopping = false;
  async function renderAnim(time) {
    if (origin === null) {
      origin = time;
    }
    const elapsed = (time - origin) * 1000;
    if (elapsed >= duration) {
      if (!stopping) {
        stopping = true;
        await recordAnimate(duration);
        if (recorder.state != 'inactive') {
          recorder.stop();
        }
      }
      return;
    }
    await recordAnimate(elapsed);
  }

  recorder.start();
  startExportAudio(exportAudio);
  var stopAnim = audioTimerLoop(renderAnim, 1000 / fps);

  // Safety net: never leave the UI stuck if the oscillator clock stalls
  window.setTimeout(function () {
    if (recorder.state != 'inactive') {
      recorder.stop();
    }
  }, duration + 5000);
}
