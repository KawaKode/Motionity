// For debugging purposes
db.config.debug = false;

// Check if a project exists
function checkDB() {
  db.collection('projects')
    .get()
    .then((project) => {
      if (project.length == 0) {
        canvas.clipPath = null;
        const inst = canvas.toDatalessJSON([
          'volume',
          'audioSrc',
          'defaultLeft',
          'defaultTop',
          'defaultScaleX',
          'defaultScaleY',
          'notnew',
          'starttime',
          'top',
          'left',
          'width',
          'height',
          'scaleX',
          'scaleY',
          'flipX',
          'flipY',
          'originX',
          'originY',
          'transformMatrix',
          'stroke',
          'strokeWidth',
          'strokeDashArray',
          'strokeLineCap',
          'strokeDashOffset',
          'strokeLineJoin',
          'strokeMiterLimit',
          'angle',
          'opacity',
          'fill',
          'globalCompositeOperation',
          'shadow',
          'clipTo',
          'visible',
          'backgroundColor',
          'skewX',
          'skewY',
          'fillRule',
          'paintFirst',
          'strokeUniform',
          'rx',
          'ry',
          'cornerRadius',
          'selectable',
          'hasControls',
          'subTargetCheck',
          'id',
          'hoverCursor',
          'defaultCursor',
          'filesrc',
          'isEditing',
          'source',
          'assetType',
          'duration',
          'inGroup',
          'filters',
        ]);
        canvas.clipPath = artboard;
        db.collection('projects').add({
          id: 1,
          canvas: JSON.stringify(inst),
          keyframes: JSON.stringify(keyframes.slice()),
          p_keyframes: JSON.stringify(p_keyframes.slice()),
          objects: JSON.stringify(objects.slice()),
          colormode: colormode,
          speed: speed,
          duration: duration,
          currenttime: currenttime,
          layercount: layer_count,
          width: artboard.width,
          height: artboard.height,
          animatedtext: JSON.stringify(animatedtext),
          groups: JSON.stringify(groups),
          files: JSON.stringify(files),
          activepreset: activepreset,
        });
        checkstatus = true;
        getAssets();
      } else {
        loadProject();
      }
    })
    .catch(function (e) {
      console.error('Could not open the local project database', e);
    });
}

// Automatically save project (locally)
async function autoSave() {
  if (checkstatus) {
    canvas.clipPath = null;
    // Sequential, not forEach(async): toDatalessJSON below must not run
    // while filters are still being stripped off the objects.
    for (const object of objects) {
      var obj = canvas.getItemById(object.id);
      if (!obj) {
        object.filters = [];
        continue;
      }
      if (obj.filters) {
        if (obj.filters.length > 0) {
          object.filters = [];
          obj.filters.forEach(function (filter) {
            if (
              filter.type == 'BlackWhite' ||
              filter.type == 'Invert' ||
              filter.type == 'Sepia' ||
              filter.type == 'Kodachrome' ||
              filter.type == 'Polaroid' ||
              filter.type == 'Technicolor' ||
              filter.type == 'Brownie' ||
              filter.type == 'Vintage'
            ) {
              object.filters.push({ type: filter.type });
            } else if (filter.type == 'Brightness') {
              object.filters.push({
                type: filter.type,
                value: filter.brightness,
              });
            } else if (filter.type == 'Contrast') {
              object.filters.push({
                type: filter.type,
                value: filter.contrast,
              });
            } else if (filter.type == 'Vibrance') {
              object.filters.push({
                type: filter.type,
                value: filter.vibrance,
              });
            } else if (filter.type == 'Saturation') {
              object.filters.push({
                type: filter.type,
                value: filter.saturation,
              });
            } else if (filter.type == 'HueRotation') {
              object.filters.push({
                type: filter.type,
                value: filter.rotation,
              });
            } else if (filter.type == 'Blur') {
              object.filters.push({
                type: filter.type,
                value: filter.blur,
              });
            } else if (filter.type == 'Noise') {
              object.filters.push({
                type: filter.type,
                value: filter.noise,
              });
            } else if (filter.type == 'RemoveColor') {
              object.filters.push({
                type: filter.type,
                distance: filter.distance,
                color: filter.color,
              });
            }
          });
          obj.filters = [];
          obj.applyFilters();
          var backend = fabric.filterBackend;
          if (backend && backend.evictCachesForKey) {
            backend.evictCachesForKey(obj.cacheKey);
            backend.evictCachesForKey(obj.cacheKey + '_filtered');
          }
          if (
            obj.filters.length > 0 &&
            obj.get('id').indexOf('Video') >= 0
          ) {
            await obj.setElement(obj.saveElem);
          }
        } else {
          object.filters = [];
        }
      } else {
        object.filters = [];
      }
    }
    const inst = canvas.toDatalessJSON([
      'volume',
      'audioSrc',
      'defaultLeft',
      'defaultTop',
      'defaultScaleX',
      'defaultScaleY',
      'notnew',
      'starttime',
      'top',
      'left',
      'width',
      'height',
      'scaleX',
      'scaleY',
      'flipX',
      'flipY',
      'originX',
      'originY',
      'transformMatrix',
      'stroke',
      'strokeWidth',
      'strokeDashArray',
      'strokeLineCap',
      'strokeDashOffset',
      'strokeLineJoin',
      'strokeMiterLimit',
      'angle',
      'opacity',
      'fill',
      'globalCompositeOperation',
      'shadow',
      'clipTo',
      'visible',
      'backgroundColor',
      'skewX',
      'skewY',
      'fillRule',
      'paintFirst',
      'strokeUniform',
      'rx',
      'ry',
      'cornerRadius',
      'selectable',
      'hasControls',
      'subTargetCheck',
      'id',
      'hoverCursor',
      'defaultCursor',
      'filesrc',
      'isEditing',
      'source',
      'assetType',
      'duration',
      'inGroup',
    ]);
    canvas.clipPath = artboard;
    db.collection('projects')
      .doc({ id: 1 })
      .update({
        canvas: JSON.stringify(inst),
        keyframes: JSON.stringify(keyframes.slice()),
        p_keyframes: JSON.stringify(p_keyframes.slice()),
        objects: JSON.stringify(objects.slice()),
        colormode: colormode,
        duration: duration,
        currenttime: currenttime,
        layercount: layer_count,
        speed: speed,
        audiosrc: background_key,
        animatedtext: JSON.stringify(animatedtext),
        files: JSON.stringify(files),
        groups: JSON.stringify(groups),
        activepreset: activepreset,
        width: artboard.width,
        height: artboard.height,
      })
      .catch(function (e) {
        console.error('Autosave failed', e);
      });
    objects.forEach(function (object) {
      replaceSource(canvas.getItemById(object.id), canvas);
    });
  }
}

var isSameSet = function (arr1, arr2) {
  return (
    $(arr1).not(arr2).length === 0 && $(arr2).not(arr1).length === 0
  );
};

function loadProject() {
  db.collection('projects')
    .doc({ id: 1 })
    .get()
    .then((document) => {
      var project = document;
      keyframes = JSON.parse(project.keyframes);
      p_keyframes = JSON.parse(project.p_keyframes);
      objects = JSON.parse(project.objects);
      files = JSON.parse(project.files);
      colormode = project.colormode;
      duration = project.duration;
      layer_count = project.layercount;
      speed = project.speed;
      animatedtext = JSON.parse(project.animatedtext);
      animatedtext.forEach(function (text, index) {
        var temp = new AnimatedText(text.text, text.props);
        temp.assignTo(text.id);
        animatedtext[index] = temp;
      });
      $('#speed span').html(speed.toFixed(1) + 'x');
      groups = JSON.parse(project.groups);
      activepreset = project.activepreset;
      currenttime = 0;
      canvas.clipPath = null;
      canvas.clear();
      if (webglBackend) {
        fabric.filterBackend = webglBackend;
      }
      f = fabric.Image.filters;
      canvas.loadFromJSON(JSON.parse(project.canvas), function () {
        canvas.clipPath = artboard;
        hideGuides(canvas);
        canvas.renderAll();
        $('.object-props').remove();
        $('.layer').remove();
        objects.forEach(function (object) {
          var animatethis = false;
          if (!object.animate) {
            object.animate = [];
          }
          if (!canvas.getItemById(object.id)) {
            return;
          }
          if (object.animate.length > 5) {
            if (isSameSet(object.animate, props)) {
              animatethis = true;
            }
          }
          renderLayer(canvas.getItemById(object.id), animatethis);
          if (
            !canvas.getItemById(object.id).get('assetType') ||
            canvas.getItemById(object.id).get('assetType') != 'audio'
          ) {
            props.forEach(function (prop) {
              if (
                prop != 'top' &&
                prop != 'scaleY' &&
                prop != 'width' &&
                prop != 'height' &&
                prop != 'shadow.offsetX' &&
                prop != 'shadow.offsetY' &&
                prop != 'shadow.opacity' &&
                prop != 'shadow.blur' &&
                prop != 'lineHeight'
              ) {
                renderProp(prop, canvas.getItemById(object.id));
              }
            });
            replaceSource(canvas.getItemById(object.id), canvas);
          } else {
            renderProp('volume', canvas.getItemById(object.id));
          }
        });
        keyframes.forEach(function (keyframe) {
          if (!canvas.getItemById(keyframe.id)) {
            return;
          }
          if (
            keyframe.name != 'top' &&
            keyframe.name != 'scaleY' &&
            keyframe.name != 'width' &&
            keyframe.name != 'height' &&
            keyframe.name != 'shadow.offsetX' &&
            keyframe.name != 'shadow.offsetY' &&
            keyframe.name != 'shadow.opacity' &&
            keyframe.name != 'shadow.blur' &&
            keyframe.name != 'lineHeight'
          ) {
            renderKeyframe(
              canvas.getItemById(keyframe.id),
              keyframe.name,
              keyframe.t
            );
          }
        });
        artboard.set({
          width: project.width,
          height: project.height,
        });
        canvas.renderAll();
        resizeCanvas();
        updatePanel();

        animatedtext.forEach(function (text, index) {
          text.reset(text.text, text.props, canvas);
          canvas.renderAll();
        });

        // Set defaults
        setDuration(duration);
        setTimelineZoom(5);
        checkstatus = true;

        getAssets();

        canvas.renderAll();

        animate(false, 0);

        //newLottieAnimation(100,100);
      });
    });
}

function blobToBase64(blob) {
  return new Promise((resolve, _) => {
    const reader = new FileReader();
    reader.onloadend = () => resolve(reader.result);
    reader.readAsDataURL(blob);
  });
}

async function saveFile(thumbnail, file, type, name, place, hidden) {
  file = await blobToBase64(file);
  thumbnail = await blobToBase64(thumbnail);
  uploading = false;
  var key = Math.random().toString(36).substr(2, 9);
  db.collection('assets').add({
    key: key,
    src: file,
    thumb: thumbnail,
    name: name,
    type: type,
    hidden: hidden,
  });
  if (type === 'image') {
    uploaded_images.push({
      src: file,
      thumb: thumbnail,
      key: key,
      type: 'image',
      hidden: false,
    });
    populateGrid('images-tab');
  } else if (type === 'video') {
    uploaded_videos.push({
      src: file,
      thumb: thumbnail,
      key: key,
      type: 'video',
      hidden: false,
    });
    populateGrid('videos-tab');
  }
  $('#upload-button').html(
    "<img src='assets/upload.svg'> Upload media"
  );
  $('#upload-button').removeClass('uploading');
  if (place) {
    loadImage(
      file,
      artboard.get('left') + artboard.get('width') / 2,
      artboard.get('top') + artboard.get('height') / 2,
      200
    );
  }
  save();
}

async function savePixabayImage(url, xpos, ypos, width) {
  $('#load-image').addClass('loading-active');
  fetch(url)
    .then((res) => res.blob())
    .then((blob) => {
      url = blob;
      var reader = new FileReader();
      reader.readAsDataURL(blob);
      reader.onloadend = function () {
        url = reader.result;
        var key = Math.random().toString(36).substr(2, 9);
        db.collection('assets').add({
          key: key,
          src: url,
          thumb: url,
          name: 'test',
          type: 'image',
          hidden: true,
        });
        loadImage(url, xpos, ypos, width, false);
      };
    });
}

async function saveAudio(url) {
  var reader = new FileReader();
  reader.readAsDataURL(url);
  reader.onloadend = function () {
    var key = Math.random().toString(36).substr(2, 9);
    db.collection('assets').add({
      key: key,
      src: reader.result,
      name: 'test',
      type: 'audio',
      hidden: true,
    });
    newAudioLayer(reader.result);
  };
}

async function savePixabayVideo(url, thumb, x, y) {
  $('#load-video').addClass('loading-active');
  fetch(url)
    .then((res) => res.blob())
    .then((blob) => {
      var reader = new FileReader();
      reader.readAsDataURL(blob);
      reader.onloadend = function () {
        fetch(thumb)
          .then((res) => res.blob())
          .then((blob2) => {
            var reader2 = new FileReader();
            reader2.readAsDataURL(blob2);
            reader2.onloadend = function () {
              url = reader.result;
              thumb = reader2.result;
              var key = Math.random().toString(36).substr(2, 9);
              db.collection('assets').add({
                key: key,
                src: url,
                thumb: thumb,
                name: 'test',
                type: 'video',
                hidden: true,
              });
              loadVideo(url, x, y, false);
            };
          });
      };
    });
}

function deleteAsset(key) {
  db.collection('assets')
    .doc({ key: key })
    .get()
    .then((asset) => {
      if (!asset) {
        return;
      }
      var temp = files.filter((x) => x.file == asset.src);
      if (temp.length > 0) {
        temp.forEach(function (file) {
          const object = canvas.getItemById(file.name);
          if (object) {
            deleteObject(object);
          }
          files = $.grep(files, function (a) {
            return a !== file;
          });
        });
      }
      db.collection('assets').doc({ key: key }).delete();
      if (asset.type == 'image') {
        uploaded_images = uploaded_images.filter(function (obj) {
          return obj.key !== key;
        });
        populateGrid('images-tab');
      } else {
        uploaded_videos = uploaded_videos.filter(function (obj) {
          return obj.key !== key;
        });
        populateGrid('videos-tab');
      }
    });
}

function getAssets(attempt) {
  attempt = attempt || 0;
  db.collection('assets')
    .get()
    .then((assets) => {
      // Sometimes the assets aren't ready when importing, really annoying.
      // Retry on a timer with a hard cap - a bare synchronous re-call spins
      // the CPU forever when the collection never resolves.
      if (assets === undefined) {
        if (attempt < 20) {
          window.setTimeout(function () {
            getAssets(attempt + 1);
          }, 250);
        } else {
          console.error('Could not read assets from the local database');
        }
      } else if (assets.length > 0) {
        // Rebuild rather than append: getAssets() runs again after an import
        uploaded_images = [];
        uploaded_videos = [];
        assets.forEach(function (asset) {
          if (asset.type == 'image') {
            uploaded_images.push({
              src: asset.src,
              thumb: asset.thumb,
              key: asset.key,
              type: 'image',
              hidden: asset.hidden,
            });
          } else if (asset.type == 'video') {
            uploaded_videos.push({
              src: asset.src,
              thumb: asset.thumb,
              key: asset.key,
              type: 'video',
              hidden: asset.hidden,
            });
          }
        });
      }
    })
    .catch(function (e) {
      console.error('Could not read assets', e);
    });
}

function readTextFile(file, callback) {
  var rawFile = new XMLHttpRequest();
  rawFile.overrideMimeType('application/json');
  rawFile.open('GET', file, true);
  rawFile.onreadystatechange = function () {
    if (rawFile.readyState === 4) {
      // A blob: URL resolves with status 0
      if (rawFile.status == 200 || rawFile.status === 0) {
        callback(rawFile.responseText);
      } else {
        alert('Could not read the file');
        $('#import-project span').html('Import');
      }
    }
  };
  rawFile.onerror = function () {
    alert('Could not read the file');
    $('#import-project span').html('Import');
  };
  rawFile.send(null);
}

async function importProject(e) {
  $('#import-project span').html('Importing...');
  var file = e.target.files[0];
  var path = (window.URL || window.webkitURL).createObjectURL(file);
  readTextFile(path, function (text) {
    var data;
    try {
      data = JSON.parse(text);
    } catch (e) {
      data = null;
    }
    if (!data || !Array.isArray(data.project) || data.project.length == 0) {
      alert('Wrong file type');
      $('#import-project span').html('Import');
      return;
    }
    delete data.project[0].id;
    {
      if (Array.isArray(data.assets) && data.assets.length > 0) {
        data.assets.forEach(function (asset) {
          delete asset.id;
          db.collection('assets').add(asset);
        });
      }
      db.collection('projects')
        .doc({ id: 1 })
        .update(data.project[0])
        .then((response) => {
          $('#import-project span').html('Import');
          hideModals();
          loadProject();
        })
        .catch(function (e) {
          console.error('Import failed', e);
          alert('Import failed');
          $('#import-project span').html('Import');
        });
    }
    window.URL.revokeObjectURL(path);
  });
}

function importHandle() {
  $('#import').click();
}

function exportProject() {
  $('#export-project span').html('Exporting...');
  db.collection('projects')
    .get()
    .then((project) => {
      if (project.length > 0) {
        db.collection('assets')
          .get()
          .then((assets) => {
            var exportarr = { project: project, assets: assets };
            // Blob, not a data: URL - projects with media blow past the
            // maximum URL length.
            const url = URL.createObjectURL(
              new Blob([JSON.stringify(exportarr)], {
                type: 'application/json',
              })
            );
            const a = document.createElement('a');
            a.style.display = 'none';
            a.href = url;
            a.download = 'data.json';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            window.setTimeout(function () {
              URL.revokeObjectURL(url);
            }, 60000);
            $('#export-project span').html('Export');
          });
      } else {
        alert('Empty project');
        $('#export-project span').html('Export');
      }
    });
}

$(document).on('click', '#import-project', importHandle);
$(document).on('click', '#export-project', exportProject);
$(document).on('change', '#import', importProject);

function clearProject() {
  if (
    window.confirm(
      'Are you sure you want to clear this project? This action cannot be undone.'
    )
  ) {
    Promise.all([
      db.collection('projects').delete(),
      db.collection('assets').delete(),
    ])
      .catch(function (e) {
        console.error('Could not clear the project', e);
      })
      .then(function () {
        location.reload();
      });
  }
  hideMore();
}
$(document).on('click', '#clear-project', clearProject);
