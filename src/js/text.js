function animateText(group, ms, play, props, cv, id) {
  const p_keyframe = p_keyframes.find((x) => x.id == id);
  if (!group || !p_keyframe) {
    return;
  }
  ms -= p_keyframe.start;
  var length = group._objects.length;
  var globaldelay = 0;
  // Every letter needs its own binding: the anime callbacks below run long
  // after the loop has finished, so `var` would make them all share the last
  // letter's state.
  for (var i = 0; i < length; i++) {
    let index = i;
    if (props.order == 'backward') {
      index = length - i - 1;
    }
    let left = group.item(index).defaultLeft;
    let top = group.item(index).defaultTop;
    let scaleX = group.item(index).defaultScaleX;
    let scaleY = group.item(index).defaultScaleY;
    // Named `step` so it does not shadow the global project duration
    let step = props.duration / length;
    let delay = i * step;
    let animation = {
      opacity: 0,
      top: top,
      left: left,
      scaleX: scaleX,
      scaleY: scaleY,
    };
    if (props.typeAnim == 'letter') {
      delay = i * step - 100;
    } else if (props.typeAnim == 'word') {
      if (group.item(index).text == ' ') {
        globaldelay += 500;
      }
      delay = globaldelay;
    }
    if (props.preset == 'typewriter') {
      delay = i * step;
      step = 20;
    } else if (props.preset == 'fade in') {
    } else if (props.preset == 'slide top') {
      animation.top += 20;
    } else if (props.preset == 'slide bottom') {
      animation.top -= 20;
    } else if (props.preset == 'slide left') {
      animation.left += 20;
    } else if (props.preset == 'slide right') {
      animation.left -= 20;
    } else if (props.preset == 'scale') {
      animation.scaleX = 0;
      animation.scaleY = 0;
    } else if (props.preset == 'shrink') {
      animation.scaleX = 1.5;
      animation.scaleY = 1.5;
    }
    if (!(delay > 0)) {
      delay = 0;
    }
    if (!(step > 20)) {
      step = 20;
    }
    let start = false;
    let instance = anime({
      targets: animation,
      delay: delay,
      opacity: 1,
      left: left,
      top: top,
      scaleX: scaleX,
      scaleY: scaleY,
      duration: step,
      easing: props.easing,
      autoplay: play,
      update: function () {
        if (start && play) {
          group.item(index).set({
            opacity: animation.opacity,
            left: animation.left,
            top: animation.top,
            scaleX: animation.scaleX,
            scaleY: animation.scaleY,
          });
          cv.renderAll();
        }
      },
      changeBegin: function () {
        start = true;
      },
    });
    instance.seek(ms);
    if (!play) {
      group.item(index).set({
        opacity: animation.opacity,
        left: animation.left,
        top: animation.top,
        scaleX: animation.scaleX,
        scaleY: animation.scaleY,
      });
      cv.renderAll();
    }
  }
}

function setText(group, props, cv) {
  var length = group._objects.length;
  for (var i = 0; i < length; i++) {
    group.item(i).set({
      fill: props.fill,
      fontFamily: props.fontFamily,
    });
    cv.renderAll();
  }
}

function renderText(string, props, x, y, cv, id, isnew, start) {
  var textOffset = 0;
  var group = [];
  function renderLetter(letter) {
    var text = new fabric.Text(letter, {
      left: textOffset,
      top: 0,
      fill: props.fill,
      fontFamily: props.fontFamily,
      opacity: 1,
    });
    text.set({
      defaultLeft: text.left,
      defaultTop: text.top,
      defaultScaleX: 1,
      defaultScaleY: 1,
    });
    textOffset += text.get('width');
    return text;
  }
  for (var i = 0; i < string.length; i++) {
    group.push(renderLetter(string.charAt(i)));
  }
  var result = new fabric.Group(group, {
    cursorWidth: 1,
    stroke: '#000',
    strokeUniform: true,
    paintFirst: 'stroke',
    strokeWidth: 0,
    originX: 'center',
    originY: 'center',
    left: x - artboard.left,
    top: y - artboard.top,
    cursorDuration: 1,
    cursorDelay: 250,
    assetType: 'animatedText',
    id: id,
    strokeDashArray: false,
    inGroup: false,
  });
  if (isnew) {
    result.set({
      notnew: true,
      starttime: start,
    });
  }
  result.objectCaching = false;
  cv.add(result);
  cv.renderAll();
  newLayer(result);
  result._objects.forEach(function (object, index) {
    result.item(index).set({
      defaultLeft: result.item(index).defaultLeft - result.width / 2,
      defaultTop: result.item(index).defaultTop - result.height / 2,
    });
  });
  cv.setActiveObject(result);
  cv.bringToFront(result);
  return result.id;
}

class AnimatedText {
  constructor(text, props) {
    this.text = text;
    this.props = props;
    this.id = 'Text' + layer_count;
  }
  render(cv) {
    this.id = renderText(
      this.text,
      this.props,
      this.props.left,
      this.props.top,
      cv,
      this.id,
      false,
      0
    );
    animateText(
      cv.getItemById(this.id),
      currenttime,
      false,
      this.props,
      cv,
      this.id
    );
  }
  seek(ms, cv) {
    animateText(
      cv.getItemById(this.id),
      ms,
      false,
      this.props,
      cv,
      this.id
    );
  }
  play(cv) {
    animateText(
      cv.getItemById(this.id),
      0,
      true,
      this.props,
      cv,
      this.id
    );
  }
  getObject(cv) {
    return cv.getItemById(this.id);
  }
  setProps(newprops, cv) {
    this.props = $.extend(this.props, newprops);
    setText(cv.getItemById(this.id), this.props, cv);
  }
  setProp(newprop) {
    $.extend(this.props, newprop);
  }
  reset(text, newprops, cv) {
    var obj = cv.getItemById(this.id);
    var left = obj.left;
    var top = obj.top;
    var scaleX = obj.scaleX;
    var scaleY = obj.scaleY;
    var angle = obj.angle;
    var start = p_keyframes.find((x) => x.id == this.id).start;
    deleteObject(obj, false);
    this.text = text;
    this.props = newprops;
    this.inst = renderText(
      text,
      this.props,
      left,
      top,
      cv,
      this.id,
      true,
      start
    );
    cv.getItemById(this.id).set({
      angle: angle,
      scaleX: scaleX,
      scaleY: scaleY,
    });
    cv.renderAll();
    animateText(
      cv.getItemById(this.id),
      currenttime,
      false,
      this.props,
      cv,
      this.id
    );
    animate(false, currenttime);
    save();
  }
  assignTo(id, text, props) {
    this.id = id;
    if (text !== undefined) {
      this.text = text;
    }
    if (props !== undefined) {
      this.props = props;
    }
  }
}
