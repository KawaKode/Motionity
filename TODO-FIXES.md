# Bugs & Issues — audit + fixes

Audit of `src/js`, then all findings fixed. Every file below passes `node --check`.
No live browser smoke test was run (a Chrome instance held the Playwright profile
lock), so the changes are verified statically only — see **Not verified** at the end.

Legend: `[x]` fixed · P0 = feature broken · P1 = wrong data written · P2 = crash on edge path · P3 = silently wrong UI · P4 = perf/leak · P5 = cleanup

---

## P0 — Broken features

- [x] **MP4 export dead-ended and locked the UI** — `src/js/functions.js`
  The mp4 branch of `downloadRecording` was `type = 'video/mp4'`, an implicit global
  assignment that did nothing: no download, `recording` stuck at `true`, the button
  stuck on "Downloading...", and `downloadModal()` refusing to reopen until reload.
  mp4 now goes through `convertStreams(blob, 'mp4')` like gif, and a new shared
  `resetRecordingUI()` unlocks the editor on every exit path (success, unknown
  format, worker error, FileReader error, `MediaRecorder` error).

- [x] **Copying keyframes threw** — `src/js/events.js`
  `canvas.getActiveObject().isEditing` ran on `null`, because selecting keyframes
  clears the canvas selection — the normal path. The active object is now resolved
  once and guarded, and empty `$.grep` results are no longer pushed to the clipboard.

- [x] **`canvas.getItemByid` typo** — `src/js/functions.js`
  Lowercase `i`; TypeError when pasting text/`charSpacing` keyframes.

- [x] **Ctrl+Z crashed on an empty stack; Ctrl+Shift+Z was a no-op** — `src/js/events.js`
  Merged into one guarded handler: shift picks redo, and each branch checks its own
  stack length. Previously Ctrl+Shift+Z matched both `if` blocks (redo then undo).

- [x] **Blur slider threw with nothing selected** — `src/js/events.js`
  `obj.applyFilters()` was outside the `if (canvas.getActiveObject())` guard. Also
  renamed the shadowed `x` in the blur/noise/chroma `find()` callbacks.

## P1 — Wrong values written

- [x] **`height` keyframes stored the width** — `src/js/functions.js` (3 sites: twice in `keyframeChanges`, once in `crop`)
- [x] **`var scaleX = obj, scaleX;`** — `src/js/text.js`; the fabric object was being assigned as a scale factor.
- [x] **NaN letter delay + shadowed global `duration`** — `src/js/text.js`
  `delay = i * duration` read the hoisted local before its own initialiser. Renamed
  to `step`, computed before use, and `!(delay > 0)` now catches NaN.
- [x] **Every letter animation wrote to the last letter** — `src/js/text.js`
  `index`, `animation`, `start` and `instance` are `let` per iteration instead of `var`.
- [x] **Shadow defaults/keyframes stored `undefined`** — `src/js/functions.js`
  fabric's `get()` is not a path getter. Added `getPropValue()` (handles `shadow.*`)
  and `setDefaultValue()` / `getDefaultValue()`, and routed ~26 direct
  `.defaults.find(...).value = …` writes through them — which also creates the entry
  when a project predates a property instead of throwing.
- [x] **WebGL filter backend clobbered with `undefined`** — `src/js/init.js`, `src/js/database.js`
  Both assignments are now conditional on the backend having constructed.

## P2 — Crashes on edge paths

- [x] **`RangeError: Invalid array length`** — `src/js/functions.js`
  `temparr.length = findIndex(...)` went negative for a stale keyframe reference.
  `lastKeyframe` / `nextKeyframe` are now index lookups that return `false`.
- [x] **`animate()` had no null guards** — `src/js/functions.js`
  Object and `p_keyframes` lookups are resolved once and guarded in every per-frame
  loop (`animate`, `recordAnimate`, the playback update loop, `playVideos`,
  `playAudio`), which also removed dozens of repeated `.find()` calls.
- [x] **`getAssets()` recursed synchronously forever** — `src/js/database.js`
  Retries on a 250 ms timer, capped at 20 attempts, and rebuilds the asset arrays
  instead of appending duplicates on re-entry after an import.
- [x] **`deleteObject` threw and leaked `files`** — `src/js/functions.js`
  The entry was compared to a string so it never matched; now filtered by `name`.
  Video elements are also paused and unloaded on delete.
- [x] **Unguarded `keyarr[0]` / `.defaults.find(...)`** — `copyKeyframes`, `updateKeyframe`,
  `applyEasing`, `keyframeProperties`, `removeKeyframe`, `checkAnyKeyframe`.
  The four repetitive counterpart blocks were replaced by one
  `KEYFRAME_COUNTERPARTS` map, so a missing counterpart is skipped, not fatal.
- [x] **Other unguarded lookups** — `deleteAsset`, `reGroup`, `renderLayer`,
  `renderProp`, `setDuration`, `setTimelineZoom`, `saveLayerName`, `updateInputs`,
  `updatePanel`, `updateStrokeValues`, `animateText`, `scrollIntoView` (3 sites),
  `object:modified` / `object:rotating` / `mouse:out` / `mouse:up` handlers.
  `importProject` validates the payload before touching `data.project[0]`, and
  `line_h`/`line_v` go through a new `hideGuides()` helper.

## P3 — Silently wrong behaviour

- [x] **`document.onmousedown` permanently disabled** — `src/js/functions.js`
  `dragTimeline` installed a `return false` handler and never removed it. It now
  only overrides `onselectstart`, and restores it on mouseup.
- [x] **Keyframe time drifted on every drag** — `src/js/functions.js`
  `data-time` is now always the absolute timeline time (the value every lookup keys
  off), with the visual offset applied as CSS only. This also fixes keyframes on an
  *expanded* row, whose `data-time` used to be layer-relative so no lookup matched.
  `updateKeyframe`'s unused third argument is gone.
- [x] **Shift-deselect never removed a keyframe** — `this` inside a `$.grep` callback is not the element.
- [x] **`e.shiftDown`** → `e.shiftKey`.
- [x] **Snap guide never hid** — the row-local index was compared against the global `.keyframe` count.
- [x] **Comparison / typo bugs**
  `canvas.getActiveObjects.length` → `getActiveObjects().length` ·
  `strokeDashArray == [10, 5]` → element comparison ·
  chroma `setValue(distance)` → `distance * 100` · `'#FFFFF'` → `'#FFFFFF'` ·
  `videoPlayer.videoheight` → `videoHeight` (and both thumbnail helpers no longer
  draw the canvas onto itself) · `if (start && play && !paused)` in `playAudio`
  (`play` is the global function, always truthy) · `#redo` gated on `redo.length` ·
  `:last-child()` → `:last-child`.
- [x] **Paste loop closure** — `var imgObj` → `let`, so each thumbnail saves its own file.
- [x] **Layers added mid-timeline were shortened** — `end: duration - currenttime` → `duration`
  (media layers clamp to `min(start + assetDuration, duration)`).
- [x] **Malformed HTML** — 5 unterminated `<img …'` strings and a stray `</div>` in `src/js/ui.js`.
- [x] **Duplicate DOM ids** — `id="easing"` on both wrapper and `<select>` (the select
  is now `easing-select`; `#easing select` still matches), `id="filters-title"` ×4 and
  `id='item-text'` ×6 became classes, with `src/styles.css` updated to match.
  Added the missing `<meta charset>`.

## P4 — Performance, leaks, export gaps

- [x] **`save()` rebuilt the record canvas on every edit** — `src/js/functions.js`
  `updateRecordCanvas()` + `autoSave()` now run through a 400 ms debounce
  (`schedulePersist`). `record()` still awaits `updateRecordCanvas()` directly, so an
  export always captures current state. `updateObjectValues` no longer calls
  `autoSave()` on every keystroke.
- [x] **`async forEach` raced the snapshot** — `src/js/functions.js`, `src/js/database.js`
  Both filter-stripping loops are sequential `for…of` in `async` functions, so
  `toJSON` / `toDatalessJSON` can no longer run mid-strip.
- [x] **O(n²·log n) playback** — `src/js/functions.js`
  `buildKeyframeIndex()` groups keyframes by `id|name` once per rendered frame;
  `lastKeyframe`, `nextKeyframe` and `checkAnyKeyframe` use it instead of sorting a
  copy of the entire keyframe list per keyframe per frame. The two duplicated inner
  `nextKeyframe` copies are gone.
- [x] **Exports lost audio-layer sound** — `src/js/recorder.js`
  Audio layers were never routed into the capture stream. All sources (video
  elements, audio layers, background audio) now mix through **one** AudioContext
  into **one** destination track — necessary because `MediaRecorder` only records
  the first audio track. Audio layers start/stop on their `p_keyframes` boundaries.
- [x] **Export timing** — `src/js/recorder.js`
  The render clock starts after `recorder.start()` (it used to run before, losing the
  first frames), stops when the animation clock covers `duration` rather than on a
  wall-clock `setTimeout`, and has a `duration + 5s` safety stop.
- [x] **Leaks** — AudioContexts are closed and stream tracks stopped on export end;
  object URLs are revoked (`downloadRecording`, `PostBlob`, `exportProject`,
  `importProject`); the browser scroll handler is unbound before rebinding; `sortable`
  is initialised once instead of per rendered layer; deleted videos are paused and
  unloaded; category/audio grids are cleared before repopulating.

## P5 — Dead code, config, cleanup

- [x] **Unreachable code calling an undefined `waitForEvent`** — `src/js/recorder.js`
  `initRecorder` / `recordFrame` / `exportRecording` and ~180 lines of commented-out
  abandoned experiments were removed; the file is now just the live export path.
- [x] **Placeholder API keys** — `src/js/init.js`
  `HAS_FONTS_KEY` / `HAS_PIXABAY_KEY` gate the requests. Without a fonts key the
  pickers fall back to the bundled families instead of staying empty; without a
  Pixabay key search shows an explanatory message instead of 401-ing.
- [x] **`var timeout` collided with `recorder.js`'s `timeout()`** — removed (it was unused).
- [x] **Implicit globals** — `srcfreeze`, `osc`, `type`, `newcolorkeyframe` (deleted, never read).
- [x] **Duplicate / unreachable branches** — the second `shadow.blur` arm in all three
  `setValue` copies, the duplicated `objectCaching` key, the three copies of the
  keyframe sort comparator (now `sortKeyframes()`), and the two identical crop blocks
  in `events.js` (now `updateCropBounds()`).
- [x] **Converter was unfinished** — `src/js/converter.js`
  The `workerReady` handshake never fired (`buffersReady` was never set); worker
  readiness is now tracked across calls, since the worker is created once and reused.
  Added `onerror` handling, an empty-result guard, and a user-visible failure path.
- [x] **Misc** — `overlay()` no longer reuses the artboard's `overlay` id ·
  `getItemById` recurses so nested groups are found and stops at the first hit ·
  `fabric.Lottie` guards `this.canvas` before the object is added ·
  `newLottieAnimation` no longer multiplies an ms duration by 1000 ·
  lottie layers get a colour · `calculateTextWidth` honours the requested font ·
  `changeFont` / `loadImage` / `loadVideo` / `handleLottieUpload` have failure paths ·
  `checkFilter` no longer tests for a non-existent `video` fabric type ·
  `AnimatedText.assignTo` applies `text`/`props` · `animate(currenttime, false)` →
  `animate(false, currenttime)` (3 sites — text animation changes never refreshed) ·
  `exportProject` uses a Blob instead of a `data:` URL · `clearProject` reloads after
  the deletes resolve · `readTextFile` handles blob-URL status 0 and errors ·
  `.catch` added to the Localbase promises · opacity inputs clamp the input, not the
  wrapper · arrow-key nudge calls `setCoords()` and is suppressed while typing ·
  layer reorder shortcuts accept Ctrl as well as Cmd · alignment guides ignore hidden
  objects · `alignObject` saves and dropped its `console.log`.

---

---

# Frame-accurate export (new)

The real-time capture path was the root cause of "heavy scenes drop frames" and
"video layers are sampled at the wrong moment". It is now the *fallback*, not the
default.

## `src/js/render.js` — offline renderer

No clock is attached to the render. For each of `duration × 30` frames:

1. every video layer is seeked to the exact frame time and the code **awaits
   `seeked`** before drawing (a bare `currentTime =` is async — drawing straight
   after captures the *previous* frame, which is why real-time exports smeared
   video layers);
2. lottie layers are advanced to the same time;
3. `recordAnimate(time)` lays out the frame, `canvasrecord.renderAll()` draws it;
4. a `VideoFrame` is built from the canvas with an explicit timestamp and pushed
   through a `VideoEncoder` (VP9, falling back to VP8), with the encoder queue
   held at ≤ 8 frames so memory stays bounded.

Audio is mixed in one `OfflineAudioContext` pass — every audio layer, every video
layer's soundtrack and the background track, each placed at its own
`start`/`trimstart`/`end` with its own gain — then encoded to Opus with
`AudioEncoder`. Sample-accurate, and unlike the live path it does not depend on
playback keeping up.

Both tracks are sorted by timestamp and muxed into one WebM.

`recordAnimate()` skips `playVideos()` while `offlinerender` is set, so real-time
playback cannot fight the explicit seeking.

## `src/js/webm-writer2.js` — extended

Was single-track video only, and unreferenced by `index.html`. Now loaded, and:

- optional second **Opus** track (`A_OPUS` + 19-byte `OpusHead` CodecPrivate,
  `CodecDelay`, `SeekPreRoll`, `Audio` element with sample rate/channels);
- `addFrame(chunk, trackNumber)` accepts `EncodedAudioChunk` as well as
  `EncodedVideoChunk`; `addFrameToCluster` no longer hardcodes track 1.

Three bugs fixed in the vendored library along the way:

- **`MAX_CLUSTER_DURATION_MSEC` was `5000000`** (~58 days), so every frame went
  into a single cluster and block timecodes — a signed 16-bit offset — overflowed
  past ~32 s. Now 5000 ms, and clusters close on a video keyframe.
- **The header buffer was a fixed 256 bytes**, which a second `TrackEntry`
  overflows (`ArrayBufferDataStream's pos lies beyond end of buffer`). Now 1024.
- **`instanceof Uint8Array`** for byte payloads fails across a realm boundary;
  `ArrayBuffer.isView` is now accepted too.

## Safety net

The muxer is hand-rolled, so `renderFrameAccurate()` loads the finished blob into
a `<video>` element and checks it decodes before handing it over. Any failure —
no WebCodecs, unsupported codec, encoder error, failed verification — returns
`null` and `record()` transparently falls back to the real-time encoder.

## Tests — `test/webm-muxer.test.js`

Runs in plain Node (no deps): `node test/webm-muxer.test.js`

Loads the muxer in a VM context, feeds fake encoded chunks, then parses the
resulting bytes with a small EBML reader and asserts the EBML header, Segment,
one or two `TrackEntry` with the right `CodecID`/`TrackType`, a 19-byte
`OpusHead`, multiple clusters, every block present on the right track, block
timecodes inside signed 16-bit range, ascending cluster timecodes, and that
`cluster timecode + block timecode` reconstructs the input timestamps to within
1 ms. Covers video-only and video+audio at 75 s (13 clusters, 3000 blocks).

Both cases pass. The 256-byte header bug above was caught by this test, not by
inspection.

---

## Left in place deliberately

- **`src/js/encode-worker.js`** is still unreferenced. It was the old
  File-System-Access-API sketch; `render.js` supersedes it and buffers to memory
  instead of requiring a save-file picker. Deleting it is a product decision.
- **MP4 and GIF** go through ffmpeg.wasm (`converter.js`), vendored out of
  `node_modules` and pinned by `package-lock.json`. This replaced the asm.js
  worker loaded from archive.org, which had no integrity check and needed the
  network. See "ffmpeg.wasm migration" below.

---

# ffmpeg.wasm migration (new)

MP4/GIF export used to `importScripts()` an 18.5 MB asm.js ffmpeg build from
`https://archive.org/download/ffmpeg_asm/ffmpeg_asm.js` — no integrity check, no
pinning, and executed in the page. `scripts/vendor.mjs` now **copies**
ffmpeg.wasm out of `node_modules`, where `package-lock.json` pins it by hash.
There is no CDN fallback left anywhere in the app.

Three things this ran into, all of which cost a debugging round:

- **`@ffmpeg/core` needs `SharedArrayBuffer`.** The default core is built with
  pthreads, which requires COOP/COEP cross-origin isolation, which would break
  the Pixabay, Unsplash and Google Fonts requests. `@ffmpeg/core-st` — the
  single-threaded build — is used instead. Verified: the core loads with
  `crossOriginIsolated === false` and `SharedArrayBuffer` undefined.
- **`mainName: 'main'` is mandatory with that core.** The loader defaults to
  `proxy_main`, which only the multi-threaded build exports. Without it, `load()`
  compiles all 23 MB and then aborts with *Cannot call unknown function
  proxy_main*.
- **One conversion per load.** The single-threaded core's `main` calls `exit()`,
  so a second `run()` on the same instance dies with *Program terminated with
  exit(0)*. `convertStreams` therefore builds and tears down an instance per
  conversion — measured at ~110 ms, and it returns the 23 MB heap in between.
  The teardown also runs on failure: an interrupted run otherwise leaves the
  loader's internal "running" flag set and every later conversion fails with
  *can only run one command at a time* until the page is reloaded.

MP4 now encodes with `libx264 -crf 23 -pix_fmt yuv420p` plus AAC audio rather
than `mpeg4 -b:v 6400k`. Same core, better quality per byte, and `yuv420p` is
what makes it play in Safari and QuickTime.

`WITH_FFMPEG=0` no longer means "download it at run time" — it means MP4/GIF
export is unavailable, and `converter.js` says so instead of failing obscurely.

Verified in Chromium against a real MediaRecorder WebM: MP4 24 KB with an
`ftypisom` header that decodes to 320x240 / 2.00 s, GIF 138 KB with a `GIF89a`
header, the two run back to back, and the missing-core path produces the right
message.

---

## Not verified

`node --check` passes on every script; the muxer is covered by the Node test
above. The app itself was **not** loaded in a browser (a running Chrome instance
held the Playwright profile lock), so the following still needs a manual pass:

1. `cd src && python -m http.server 8765`, open `http://localhost:8765`
2. Add a shape, keyframe it, drag the keyframe, scrub, undo/redo
3. Export as WEBM with a video layer and an audio layer present — confirm the
   console shows `Rendering n%` (frame-accurate path) and not
   `Falling back to the real-time encoder`
4. Play the result: check audio is in sync and the video layer is not smeared

---

## Upstream open issues (alyssaxuu/motionity)

The 13 bug reports still open upstream were replayed in Chromium against this
fork. Nine were already fixed by the audit above — mp4 export (#16), blank
render (#25), image download (#10), audio on download (#30), filters not
retained (#24), `EyeDropper is not defined` (#15, #18), the endless
*Loading video…* (#28) and text selection while resizing the timeline (#5).
GIF export (#21) works through the same ffmpeg path. #8 (video from the search
tab) needs a Pixabay API key, so it stays untested; #29 and #4 carry no
reproducer. The remaining three are fixed here:

- [x] **#23 — Border radius behaved like a percentage** — `src/js/functions.js`,
  `src/js/ui.js`, `src/js/events.js`, `src/js/database.js`
  fabric applies `rx`/`ry` before the object's scale, and shapes are resized by
  scaling, so a radius typed as 20 drew at 60 px on a rect scaled 3x while the
  panel — which read `rx` back raw — still said 20. A new `cornerRadius` property
  stores the pixel value the user asked for; `rx`/`ry` are derived from it
  (`setCornerRadius`) and re-derived on `object:scaling` / `object:modified`
  (`syncCornerRadius`), so the same number means the same pixels at any size.
  `cornerRadius` was added to the four serialised property lists, and
  `getCornerRadius` falls back to `rx * scaleX` for projects saved before it
  existed. Known limit, unchanged from before: if `scaleX` is *keyframed*, the
  drawn radius still varies over the animation.
  Verified: typed 20 px draws a 20 px corner at scale 1 and at scale 3, the
  panel keeps reading 20, and the value survives save, JSON round-trip and a
  page reload.

- [x] **#27 — Cropping a rotated image** — `src/js/functions.js`
  `crop()` compared canvas-space edges and covered only three of the four
  quadrants, so any rotated image cropped the wrong region — and nothing at all
  when the crop window was centred on it, since all three branches need a
  strictly positive offset. The guards added in the audit stopped the crash but
  left the geometry wrong. `crop()` now works in the image's own frame
  (`rotateVector`), clamps the region to the bitmap, and re-centres the object on
  the region it kept; the crop window is created with the image's `angle`, and
  the "expand back to the full bitmap" shift in `cropImage` is rotated the same
  way. The four-branch soup is gone.
  Verified: at 0°, 30° and 45°, the pixels under the crop window are byte
  identical before and after the crop, everything outside it is dropped, and
  crop mode exits cleanly.

- [x] **#1 — A modal did not block the timeline** — `src/js/functions.js`
  Modals are painted over the timeline but never took its pointer events, so the
  resize handle, the seekbar, keyframes and layer bars all still reacted to a
  drag behind the dialog. The onboarding modal from the report does not exist in
  the open-source build; the export, import/export and credits modals all had
  the bug. `dragTimeline`, `dragSeekBar`, `dragKeyframe` and `dragObjectProps`
  now bail while `.modal-open` is present.
  Verified: with the export modal open a real mouse drag on the handle leaves
  the timeline height untouched, and dragging works again once it closes.
