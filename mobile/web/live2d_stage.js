// Live2D Cubism stage bootstrap for the companion (web).
//
// Exposes a tiny imperative API on window.__live2dStage that the Dart side
// drives through js_interop:
//   mount(containerId, modelUrl)  – create PIXI app + load the Cubism model
//   setParam(id, value)           – raw parameter write (AngleX/Y/Z, Mouth…)
//   focus(x, y)                   – normalized gaze (-1..1)
//   nod()                         – keyframed head-nod gesture
//   shake()                       – keyframed body shake
//   dispose()
//
// Breath + blink run on an internal ticker so they stay smooth regardless of
// Flutter frame pacing.

window.__live2dStage = (function () {
  let app = null;
  let model = null;
  let tickerJobs = null;
  let containerEl = null;

  function fitAll() {
    if (!model || !containerEl) return;
    var w = Math.max(1, containerEl.clientWidth);
    var h = Math.max(1, containerEl.clientHeight);
    model.scale.set(Math.min(
      w / model.internalModel.originalWidth,
      h / model.internalModel.originalHeight
    ) * 1.15);
    model.x = w / 2;
    model.y = h * 0.42;
    if (app) app.renderer.resize(w, h);
  }
  const state = { blink: 1, breath: 0.5, mouth: 0, angleX: 0, angleY: 0 };
  let loadFailed = false;

  function applyIdle(t) {
    if (!model) return;
    state.breath = 0.5 + 0.5 * Math.sin(t / 1600);
    // Blink: quick close every 2–5 s.
    const period = 3400;
    const phase = t % period;
    state.blink =
      phase < 130 ? Math.max(0, 1 - phase / 65) : 1;
    setRaw("ParamBreath", state.breath);
    setRaw("ParamEyeLOpen", state.blink);
    setRaw("ParamEyeROpen", state.blink);
    setRaw("ParamMouthOpenY", state.mouth);
  }

  function setRaw(id, v) {
    if (!model) return;
    const core = model.internalModel
      ? model.internalModel.coreModel
      : null;
    if (!core) return;
    const index = core.getParameterIndex
      ? core.getParameterIndex(id)
      : -1;
    if (index >= 0) core.setParameterValueByIndex(index, v);
  }

  function startTicker() {
    if (tickerJobs || !window.PIXI) return;
    tickerJobs = true;
    window.PIXI.Ticker.shared.add((_) => applyIdle(performance.now()));
  }

  return {
    supported: function () {
      return !!(window.PIXI && window.PIXI.live2d &&
        window.Live2DCubismCore);
    },
    mount: function (containerId, modelUrl) {
      const el = document.getElementById(containerId);
      if (!el) return false;
      return this.mountElement(el, modelUrl);
    },

    /// Preferred entry: pass the container ELEMENT directly so no DOM
    /// lookup/timing race exists between Flutter and this script.
    mountElement: function (el, modelUrl) {
      const container = el;
      if (!container) return false;
      containerEl = container;
      if (!this.supported()) {
        loadFailed = true;
        container.innerHTML =
          '<div style="color:#b45309;font:12px sans-serif;padding:12px">' +
          'Live2D libraries failed to load (vendor/*.js)</div>';
        return false;
      }
      container.innerHTML = "";
      // resizeTo keeps the canvas in sync with Flutter's platform-view
      // layout, which is 0x0 at factory time and sizes later.
      app = new PIXI.Application({
        backgroundAlpha: 0,
        autoStart: true,
        resizeTo: container,
      });
      container.appendChild(app.view);
      if (window.ResizeObserver) {
        if (this._ro) this._ro.disconnect();
        this._ro = new ResizeObserver(function () {
          fitAll();
        });
        this._ro.observe(el);
      }
      PIXI.live2d.Live2DModel.from(modelUrl).catch(function (err) {
        loadFailed = true;
        console.error('[companion] Live2D model load failed:', err);
        container.innerHTML =
          '<div style="color:#b91c1c;font:12px sans-serif;padding:12px">' +
          'Live2D model failed to load — see console</div>';
        throw err;
      }).then(function (m) {
        model = m;
        m.anchor.set(0.5, 0.35);
        window.addEventListener('resize', fitAll);
        fitAll();
        app.stage.addChild(m);
        startTicker();
      });
      return true;
    },
    setParam: function (id, v) {
      state[id] = v;
      setRaw(id, v);
    },
    focus: function (x, y) {
      if (!model) return;
      state.angleX = x * 30;
      state.angleY = -y * 30;
      setRaw("ParamAngleX", state.angleX);
      setRaw("ParamAngleY", state.angleY);
      setRaw("ParamBodyAngleZ", x * 10);
      if (model.focusController) {
        model.focusController.focus(x, -y);
      }
    },
    nod: function () {
      if (!model) return;
      const seq = [0, 12, 0, -6, 0];
      seq.forEach(function (deg, i) {
        setTimeout(function () { setRaw("ParamAngleY", deg); }, i * 110);
      });
    },
    shake: function () {
      if (!model) return;
      const seq = [6, -8, 5, -4, 0];
      seq.forEach(function (deg, i) {
        setTimeout(function () { setRaw("ParamBodyAngleZ", deg); }, i * 90);
      });
    },
    hasLoadFailed: function () {
      return !!loadFailed;
    },
    dispose: function () {
      if (app) { app.destroy(false, { children: true }); }
      app = null; model = null; tickerJobs = null;
    },
  };
})();
