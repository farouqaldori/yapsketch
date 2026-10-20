// One clock drives speech, ink, cursor, levels and handoff. No dependencies.
(() => {
  const demo = document.querySelector("#demo");
  const pens = [...demo.querySelectorAll(".pen")];
  const cursor = demo.querySelector(".cursor");
  const meter = [...demo.querySelectorAll(".meter i")];
  // On phones the screen runs past both edges (135% wide), and the window runs off them too:
  // its content fills the visible middle, and its sides and bottom are cropped, like the video.
  if (matchMedia("(max-width: 1000px)").matches) {
    demo.querySelectorAll("[transform='translate(400 221) scale(1.122) translate(-400 -199)']").forEach((g) =>
      g.setAttribute("transform", "translate(400 203) scale(0.88) translate(-400 -199)"),
    );
  }
  // The window sits on the wallpaper (moved and scaled): marks and the cursor live in its coordinates.
  const desk = demo.querySelector(".desk").transform.baseVal.consolidate().matrix;
  const onDesk = (p) => new DOMPoint(p.x, p.y).matrixTransform(desk.inverse());
  const timer = demo.querySelector(".timer");
  const scene = demo.querySelector(".scene");
  const toolbar = demo.querySelector(".toolbar");
  const output = demo.querySelector(".output");
  const q = (sel) => demo.querySelector(sel);
  const parts = {
    status: q(".status"),
    tools: q(".record-tools"),
    spinnerBox: q(".processing"),
    spinner: q(".spinner"),
    copied: q(".copied"),
    tickCircle: q(".tick circle"),
    tickPath: q(".tick path"),
    copy: q(".copy"),
    stop: q(".stop"),
    tip: q(".tip"),
    scrim: q(".scrim"),
    pics: [...demo.querySelectorAll(".pic")],
  };
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  // ?t=7000 holds the demo at that moment (for screenshots).
  const still = new URLSearchParams(location.search).get("t");

  // How far into its script the demo starts (0: it plays from the very beginning, voice included).
  const SHIFT = 0;
  // The script, on the video's clock (shifted so the voice starts at 0.4 s): what's said when, and when
  // each mark, the pill and the report appear.
  const T = {
    pen: 3700, // the pen is picked up: the cursor stays a pen until you stop
    circle: [5150, 5750], // the badge that overlaps the number
    box: [7300, 7750], // the broken image
    tip: 9700, // the cursor hovers the chart: its tooltip shows
    arrow: [10800, 11350], // the tooltip the chart cuts off
    stop: 16500,
    stopped: 17350,
    done: 17700, // the pill: report ready
    pasted: 18160, // the report window
    copy: 21200, // Copy is pressed
    leave: 24500, // the pill and card collapse, the marks and caption fade: a clean screen to restart on
    duration: 26000,
  };
  const LENGTH = T.duration - SHIFT; // what the timeline and the loop run over
  // What's said, word by word as the voice says it (ms into the recording, then the voice's own start).
  const VOICE_AT = 400;
  const speech = [[["Okay",40,360],["so",520,699],["I",699,828],["want",828,1109],["you",1109,1340],["to",1340,1520],["fix",1520,1750],["a",1750,1878],["few",1878,2109],["issues",2109,2494],["here",2494,2775],["on",2775,2955],["my",2955,3134],["website",3134,3570]],[["This",4160,4480],["badge",4480,4859],["overlaps",4859,5411],["the",5411,5673],["number",5673,6110]],[["the",6430,6713],["image",6713,7122],["here",7122,7468],["is",7468,7688],["broken",7688,8160]],[["and",8600,8828],["the",8828,9057],["tooltip",9057,9488],["on",9488,9666],["the",9666,9894],["graph",9894,10224],["gets",10224,10503],["cut",10503,10732],["off",10732,10960]],[["Fix",11640,11939],["it",11939,12172],["all",12172,12471],["please",12471,12970],["and",13180,13370],["yeah",13610,13880],["make",13880,14151],["no",14151,14323],["mistakes",14323,14790]]];
  // How loud the voice is, every STEP ms (measured from the voice file itself).
  const STEP = 50;
  const LEVELS = [0,1,0.86,0.87,0.98,0.8,0.59,0.18,0,0,0.49,0.64,0.68,0.66,0.94,0.98,0.93,0.91,0.9,0.8,0.58,0.12,0,0.64,0.73,0.67,0.75,0.87,0.65,0.65,0.69,0.71,0.49,0.04,0.66,0.91,0.55,0.67,0.64,0.43,0.1,0.15,0.39,0.55,0.75,0.77,0.68,0.78,0.78,0.72,0.67,0.72,0.7,0.62,0.62,0.63,0.75,0.75,0.61,0.61,0.64,0.59,0.57,0.73,0.69,0.38,0.6,0.6,0.61,0.57,0.48,0.25,0,0,0,0,0,0,0,0,0,0,0.12,0.37,0.87,0.82,0.72,0.31,0.41,0.43,0.91,0.96,0.96,0.96,0.9,0.72,0.61,0.73,0.78,0.68,0.67,0.78,0.93,0.97,0.73,0.43,0.41,0.49,0.63,0.68,0.72,0.87,0.91,0.79,0.71,0.98,0.99,0.95,0.88,0.83,0.71,0.49,0.19,0.02,0,0,0,0,0.17,0.26,0.27,0.28,0.29,0.31,0.37,0.49,0.65,0.52,0.64,0.89,0.87,0.87,0.74,0.75,0.72,0.94,0.89,0.78,0.65,0.28,0,0.7,0.96,0.9,0.8,0.34,0.63,0.84,0.8,0.75,0.75,0.74,0.67,0.26,0,0,0,0,0,0,0,0,0.55,0.83,0.9,0.9,0.88,0.78,0.72,0.66,0.5,0.11,0,0.74,0.87,0.88,0.83,0.37,0.57,0.42,0.8,0.75,0.51,0.64,0.73,0.22,0.8,0.77,0.78,0.6,0.32,0.66,1.0,1,0.9,0.64,0.22,0.19,0.66,0.44,0.54,0.24,0.31,0.76,0.83,0.77,0.71,0.62,0.4,0.2,0,0,0,0,0,0,0,0,0,0,0,0,0.11,1,0.8,0.9,0.93,0.97,1,0.93,0.8,0.32,0.47,0.67,0.59,0.49,0.54,0.58,0.58,0.44,0.04,0,0.79,0.89,0.8,0.7,0.69,0.67,0.47,0.24,0,0,0,0.23,0.71,0.9,0.68,0.27,0.15,0,0,0,0.49,0.77,0.92,1,0.85,0.36,0.54,0.84,0.81,0.84,0.86,0.85,0.76,0.74,0.66,0.6,0.41,0.72,0.65,0.31,0.06,0.52,0.52,0.43,0,0,0];
  const loudness = (t) => LEVELS[Math.floor(t / STEP)] ?? 0.06;
  const said = demo.querySelector(".toolbar .said");
  const lines = speech.map((words) => {
    const line = document.createElement("span");
    line.className = "line";
    const spans = words.map(([word, at]) => {
      const span = document.createElement("span");
      span.textContent = word;
      span.dataset.t = VOICE_AT + at;
      return span;
    });
    line.append(...spans);
    said.append(line);
    return { line, spans, from: VOICE_AT + words[0][1], to: VOICE_AT + words[words.length - 1][2] };
  });

  const lengths = pens.map((path) => {
    const length = path.getTotalLength();
    path.style.strokeDasharray = length;
    return length;
  });
  const ease = (t) => {
    t = Math.max(0, Math.min(1, t));
    return t * t * (3 - 2 * t);
  };
  const progress = (ms, [a, b]) => ease((ms - a) / (b - a));
  const between = (a, b, t) => ({ x: a.x + (b.x - a.x) * ease(t), y: a.y + (b.y - a.y) * ease(t) });
  const within = (ms, [a, b]) => ms >= a && ms < b;
  let elapsed = 0,
    last = 0,
    frame = 0,
    visible = false;

  // Each stroke in order, as one hand would draw them (the arrow's head after its shaft).
  const strokes = [T.circle, T.box, T.arrow];

  // Where the cursor is: drawing each stroke, hovering the chart, and then it stays put:
  // stopping is a hotkey, so there's no trip to the stop button.
  const hover = { x: 386, y: 304 };
  function pointer(ms) {
    const along = (i, t) => pens[i].getPointAtLength(lengths[i] * t);
    if (ms < T.circle[0]) return between({ x: 440, y: 300 }, along(0, 0), (ms - T.pen) / 1200);
    if (ms < T.circle[1]) return along(0, progress(ms, T.circle));
    if (ms < T.box[0]) return between(along(0, 1), along(1, 0), (ms - 5900) / 1300);
    if (ms < T.box[1]) return along(1, progress(ms, T.box));
    if (ms < T.arrow[0]) {
      return ms < T.tip ? between(along(1, 1), hover, (ms - 8000) / 1200) : between(hover, along(2, 0), (ms - T.tip) / (T.arrow[0] - T.tip));
    }
    if (ms < T.arrow[1]) return along(2, progress(ms, T.arrow));
    return along(2, 1);
  }

  // The things that used to change by CSS transition, each a function of the clock.
  const spring = (ms, from, length) => {
    const u = (ms - from) / length;
    return u <= 0 ? 0 : u >= 1 ? 1 : 1 - Math.exp(-7 * u) * Math.cos(11 * u);
  };
  function drive(ms) {
    const L = progress(ms, [T.leave, T.leave + 500]); // everything fades out at the end
    const stopped = progress(ms, [T.stopped, T.stopped + 350]);
    const ready = progress(ms, [T.done, T.done + 450]);
    // The toolbar: full, then a spinner's worth, then the report-ready pill.
    toolbar.style.setProperty("--a", stopped.toFixed(4));
    toolbar.style.setProperty("--b", ready.toFixed(4));
    toolbar.style.scale = (1 - 0.4 * L).toFixed(4);
    toolbar.style.opacity = (1 - L).toFixed(4);
    const talking = progress(ms, [0, 200]) * (1 - progress(ms, [T.stopped, T.stopped + 150]));
    parts.status.style.opacity = talking.toFixed(3);
    parts.tools.style.opacity = (1 - progress(ms, [T.stopped, T.stopped + 150])).toFixed(3);
    parts.tools.style.filter = `blur(${(3 * progress(ms, [T.stopped, T.stopped + 150])).toFixed(2)}px)`;
    parts.stop.style.transform = `scale(${(1 - 0.15 * progress(ms, [T.stop, T.stop + 150])).toFixed(3)})`;
    // The spinner while it works, then "Report ready" with its tick and Copy.
    for (const box of [parts.spinnerBox, parts.copied]) box.style.visibility = "visible";
    parts.spinnerBox.style.opacity = (progress(ms, [T.stopped + 350, T.stopped + 600]) * (1 - progress(ms, [T.done, T.done + 150]))).toFixed(3);
    parts.spinner.style.transform = `rotate(${(ms * 0.36) % 360}deg)`;
    parts.copied.style.opacity = progress(ms, [T.done + 350, T.done + 600]).toFixed(3);
    parts.tickCircle.style.scale = Math.max(0, spring(ms, T.done + 200, 450)).toFixed(3);
    parts.tickPath.style.strokeDashoffset = (16 * (1 - progress(ms, [T.done + 450, T.done + 750]))).toFixed(2);
    const press = (ms - T.copy) / 400;
    parts.copy.style.transform = `scale(${(press > 0 && press < 1 ? 1 + 0.14 * Math.sin(Math.PI * press) : 1).toFixed(3)})`;
    // The report window and its pictures.
    const card = progress(ms, [T.pasted, T.pasted + 450]);
    output.style.opacity = (card * (1 - L)).toFixed(3);
    output.style.transform = `translateY(${(14 * (1 - card)).toFixed(2)}px) scale(${(0.96 + 0.04 * card).toFixed(4)})`;
    parts.pics.forEach((pic, i) => {
      const p = progress(ms, [T.pasted + 700 + i * 150, T.pasted + 1050 + i * 150]);
      pic.style.opacity = p.toFixed(3);
      pic.style.transform = `translateY(${(6 * (1 - p)).toFixed(2)}px)`;
    });
    parts.scrim.style.opacity = (0.38 * progress(ms, [T.pasted, T.pasted + 500]) * (1 - L)).toFixed(3);
    // What was drawn: the tooltip, the cursor and the ink.
    parts.tip.style.opacity = (progress(ms, [T.tip, T.tip + 200]) * (1 - L)).toFixed(3);
    cursor.style.opacity = (1 - progress(ms, [T.stopped, T.stopped + 300])).toFixed(3);
    pens.forEach((pen) => (pen.style.opacity = (1 - L).toFixed(3)));
  }

  function render(at) {
    controls.show(at);
    const ms = at + SHIFT;
    const recording = ms < T.stopped,
      done = ms >= T.done;
    // While recording the toolbar has a status line (recording, levels, time, then your words);
    // between points one sentence gives way to the next.
    const now = recording ? lines.findLast((l) => ms >= l.from - 150) : null;
    demo.className =
      "demo animated" +
      (recording ? " recording" : " processing-state") +
      (recording ? " talking" : "") +
      (within(ms, [T.pen, T.stop]) ? " drawing" : "") +
      (within(ms, [T.tip, T.leave]) ? " tip-on" : "") +
      (within(ms, [T.copy, T.copy + 450]) ? " copying" : "") +
      (within(ms, [T.stop, T.stopped]) ? " stopping" : "") +
      (done ? " finished" : "") +
      (ms >= T.pasted ? " pasted" : "") +
      (ms >= T.leave ? " leaving" : "");

    for (const l of lines) {
      l.line.classList.toggle("now", l === now);
      l.spans.forEach((w) => w.classList.toggle("on", ms > +w.dataset.t));
      if (l === now) {
        // Measured from the words themselves: once the line slides right, scrollWidth shrinks back
        // to the box's width, and measuring that would flip it on and off every frame.
        const gap = parseFloat(getComputedStyle(l.line).columnGap) || 0;
        const used = l.spans.reduce((w, s) => (s.classList.contains("on") ? w + s.offsetWidth + gap : w), 0) - gap;
        l.line.classList.toggle("tail", used > said.clientWidth - 14);
      } else l.line.classList.remove("tail"); // an old line's slide must not fade the next one's left edge
    }
    // The bars are the voice's own loudness, newest on the right, so they move as it speaks.
    meter.forEach((bar, i) => {
      const level = recording ? loudness(ms - VOICE_AT - (meter.length - 1 - i) * STEP) : 0.06;
      bar.style.transform = `scaleY(${(0.14 + 0.86 * level).toFixed(3)})`;
    });

    strokes.forEach((w, i) => {
      const drawn = progress(ms, w);
      pens[i].style.strokeDashoffset = lengths[i] * (1 - drawn);
      pens[i].style.visibility = drawn > 0 ? "visible" : "hidden"; // a round cap would show as a dot
    });

    const p = pointer(ms);
    cursor.setAttribute("transform", `translate(${p.x.toFixed(2)} ${p.y.toFixed(2)})`);
    timer.textContent = "00:" + String(Math.min(16, Math.floor(ms / 1000))).padStart(2, "0");

    drive(ms);
    toolbar.setAttribute("aria-hidden", String(!done));
    output.setAttribute("aria-hidden", String(ms < T.pasted));
  }

  function tick(now) {
    if (last) {
      const next = elapsed + now - last;
      elapsed = next % LENGTH;
      if (next >= LENGTH) sound.start(elapsed); // the loop begins again, and so does the voice
    }
    last = now;
    render(elapsed);
    frame = requestAnimationFrame(tick);
  }
  // It waits on its first frame until the screen is mostly in view and the scrolling has settled, then
  // plays from the top. Scroll away and it rests; scroll back and it plays from the top again.
  const PLAY_AT = 0.6, REST_BELOW = 0.2, SETTLE = 350;
  let ratio = 0,
    playing = false,
    userPaused = false,
    arming = 0,
    lastScroll = performance.now();
  addEventListener("scroll", () => (lastScroll = performance.now()), { passive: true });
  const canPlay = () => still === null && !reduce.matches && !document.hidden && !userPaused;
  function play(fromTop) {
    cancelAnimationFrame(frame);
    clearTimeout(arming);
    arming = 0;
    if (!canPlay()) return;
    if (fromTop) {
      elapsed = 0;
      render(0);
    }
    playing = true;
    last = 0;
    frame = requestAnimationFrame(tick);
    sound.start(elapsed);
    controls.sync();
  }
  function rest(reset) {
    cancelAnimationFrame(frame);
    clearTimeout(arming);
    arming = 0;
    playing = false;
    last = 0;
    sound.stop();
    if (reset) userPaused = false; // scrolled away: it starts over, playing, when it's back
    if (reset && canPlay()) {
      elapsed = 0;
      render(0);
    }
    controls.sync();
  }
  // The app's own sounds and the voice, on the same clock (dB against the recorded files).
  const CUES = [
    [SHIFT + 50, "click-start", -10],
    [SHIFT + 250, "click-dictateOn", -10],
    [T.pen, "tick-4", -16],
    [5200, "scratch-1", -24],
    [7300, "scratch-2", -24],
    [10800, "scratch-3", -24],
    [15600, "click-dictateOff", -10],
    [T.stop, "click-stop", -10],
    [T.done, "click-done", -10],
    [T.pasted + 40, "tick-1", -16],
    [T.pasted + 700, "tick-5", -16],
    [T.pasted + 850, "tick-6", -16],
    [T.pasted + 1000, "tick-7", -16],
    [19800, "chime-t1", -20],
    [19900, "chime-t2", -20],
    [20100, "chime-t3", -20],
    [T.copy, "tick-5", -16],
    [VOICE_AT, "voice", 0],
  ];
  // Browsers only let sound start after a tap, click or key press: until then the demo plays silently, and
  // the first of those starts the voice from wherever the demo is. A returning visitor's choice is kept.
  const sound = (() => {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    const files = [...new Set(CUES.map((c) => c[1]))];
    let ctx, master, loading, token = 0, sources = [];
    const buffers = {};
    let muted = false,
      volume = 1;
    try {
      muted = localStorage.getItem("yap-sound") === "off";
      volume = Math.min(1, Math.max(0, parseFloat(localStorage.getItem("yap-volume") ?? "1")));
      if (Number.isNaN(volume)) volume = 1;
    } catch {}
    const api = {
      get muted() {
        return muted;
      },
      get volume() {
        return volume;
      },
      get running() {
        return !!ctx && ctx.state === "running";
      },
      onchange: () => {},
    };
    function load() {
      if (!Ctx || ctx) return;
      ctx = new Ctx();
      master = ctx.createGain();
      master.gain.value = volume;
      master.connect(ctx.destination);
      ctx.addEventListener("statechange", () => {
        if (api.running && playing) api.start(elapsed);
        api.onchange();
      });
      loading = Promise.all(
        files.map(async (name) => {
          try {
            const bytes = await (await fetch(`audio/${name}.m4a`)).arrayBuffer();
            buffers[name] = await ctx.decodeAudioData(bytes);
          } catch {}
        }),
      );
    }
    api.stop = () => {
      token++;
      for (const s of sources) {
        try {
          s.stop();
        } catch {}
      }
      sources = [];
    };
    // From `ms` into the demo, at the moment this is called.
    api.start = (ms) => {
      api.stop();
      if (muted || !api.running) return;
      const mine = token,
        asked = performance.now();
      loading.then(() => {
        if (mine !== token) return;
        const at = ms + SHIFT + performance.now() - asked,
          t0 = ctx.currentTime - at / 1000;
        for (const [when, name, db] of CUES) {
          const buffer = buffers[name];
          if (!buffer) continue;
          const source = ctx.createBufferSource(),
            gain = ctx.createGain();
          source.buffer = buffer;
          gain.gain.value = 10 ** (db / 20);
          source.connect(gain).connect(master);
          if (when >= at) source.start(t0 + when / 1000);
          else if (name === "voice" && at - when < buffer.duration * 1000) source.start(0, (at - when) / 1000);
          else continue;
          sources.push(source);
        }
      });
    };
    // A tap, a click or a key press unlocks it.
    api.unlock = () => {
      load();
      if (ctx && ctx.state !== "running") ctx.resume().catch(() => {});
    };
    api.setVolume = (v) => {
      volume = Math.min(1, Math.max(0, v));
      try {
        localStorage.setItem("yap-volume", String(volume));
      } catch {}
      if (master) master.gain.value = volume;
      // Dragging it up from muted turns the sound back on.
      if (muted && volume > 0) api.toggle();
      else api.onchange();
    };
    api.toggle = () => {
      if (!muted && !api.running) {
        api.unlock(); // waiting on the browser, not muted: this click is what lets it start
        return;
      }
      muted = !muted;
      if (!muted && volume === 0) {
        volume = 0.6; // unmuting at zero would stay silent
        if (master) master.gain.value = volume;
      }
      try {
        localStorage.setItem("yap-sound", muted ? "off" : "on");
      } catch {}
      if (muted) api.stop();
      else {
        api.unlock();
        if (api.running && playing) api.start(elapsed);
      }
      api.onchange();
    };
    if (Ctx) {
      load();
      ctx.resume().catch(() => {});
      const unlock = () => {
        api.unlock();
        if (api.running) for (const type of events) removeEventListener(type, unlock, true);
      };
      const events = ["pointerdown", "pointerup", "touchend", "keydown", "click"];
      for (const type of events) addEventListener(type, unlock, { capture: true, passive: true });
    }
    return api;
  })();

  // The controls under the demo: play or pause, a timeline to seek in, and sound on or off.
  const controls = (() => {
    const bar = document.querySelector(".controls");
    const [playButton, soundButton] = bar.querySelectorAll(".ctl");
    const seek = bar.querySelector(".seek");
    const volumeInput = bar.querySelector(".volume");
    const time = bar.querySelector(".time");
    seek.max = LENGTH;
    let wasPlaying = false;
    const clock = (ms) => {
      const s = Math.floor(ms / 1000);
      return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    };
    const api = {
      show(ms) {
        if (!seek.matches(":active")) seek.value = ms; // while it's held, the thumb is wherever it's put
        seek.style.setProperty("--p", (ms / LENGTH).toFixed(4));
        time.textContent = clock(ms);
      },
      sync() {
        const on = playing;
        playButton.dataset.state = on ? "playing" : "paused";
        playButton.setAttribute("aria-label", on ? "Pause the demo" : "Play the demo");
        const state = sound.muted || sound.volume === 0 ? "off" : sound.running ? "on" : "locked";
        volumeInput.value = sound.muted ? 0 : sound.volume;
        volumeInput.style.setProperty("--p", volumeInput.value);
        soundButton.dataset.state = state;
        soundButton.setAttribute("aria-label", state === "on" ? "Turn sound off" : "Turn sound on");
        soundButton.setAttribute("aria-pressed", String(state === "on"));
      },
    };
    playButton.addEventListener("click", () => {
      if (playing) {
        userPaused = true;
        rest(false);
      } else {
        userPaused = false;
        if (still === null) play(false);
      }
    });
    soundButton.addEventListener("click", () => sound.toggle());
    volumeInput.addEventListener("input", () => sound.setVolume(+volumeInput.value));
    // Seeking pauses while you drag or click, then carries on from there. However it ends (a release, a
    // change, a cancelled touch) it picks up from the thumb, so a flurry of clicks can't leave it stuck.
    seek.addEventListener("input", () => {
      if (playing) {
        wasPlaying = true;
        rest(false);
      }
      elapsed = Math.min(+seek.value, LENGTH - 1);
      render(elapsed);
    });
    const finish = () => {
      const resume = wasPlaying;
      wasPlaying = false;
      if (resume && !userPaused) play(false);
      else api.sync();
    };
    for (const type of ["change", "pointerup", "pointercancel", "blur"]) seek.addEventListener(type, finish);
    sound.onchange = api.sync;
    return api;
  })();

  function arm() {
    if (playing || arming || ratio < PLAY_AT || !canPlay()) return;
    const wait = SETTLE - (performance.now() - lastScroll);
    arming = setTimeout(() => {
      arming = 0;
      if (ratio < PLAY_AT) return;
      if (performance.now() - lastScroll < SETTLE) arm();
      else play(true);
    }, Math.max(30, wait));
  }
  // Reduced motion, a held frame (?t=) and the tab going away or coming back.
  function sync() {
    if (still !== null) {
      document.documentElement.classList.add("still");
      render(+still - SHIFT);
    } else if (reduce.matches) {
      rest(false);
      render(20000);
      demo.classList.remove("animated");
    } else if (document.hidden) {
      rest(false); // keeps its place
    } else if (elapsed > 0 && ratio >= REST_BELOW && !playing) {
      play(false);
    } else {
      arm();
    }
  }
  // The toolbar is drawn at the screen's 800-wide scale; grow it with the screen (a little
  // smaller than the screen's own scale; phones have their own compact layout).
  new ResizeObserver(([entry]) => {
    const width = entry.contentRect.width;
    // The toolbar is as wide as the controls under the demo (at most 528 px) once the screen is wide
    // enough for it, and grows with the screen beyond that.
    const k = Math.max((width / 800) * 0.74, Math.min(width - 32, 528) / 420);
    scene.style.setProperty("--k", matchMedia("(max-width: 1000px)").matches ? 1 : k.toFixed(3));
  }).observe(scene);
  document.addEventListener("visibilitychange", sync);
  reduce.addEventListener("change", sync);
  new IntersectionObserver(([entry]) => {
    ratio = entry.intersectionRatio;
    if (ratio >= PLAY_AT) arm();
    else if (ratio < REST_BELOW && (playing || arming)) rest(true);
  }, { threshold: [0, REST_BELOW, PLAY_AT, 1] }).observe(scene);
  // The demo's menu bar shows the visitor's own day and time.
  const clocks = document.querySelectorAll(".clock");
  function tellTime() {
    const now = new Date();
    const text = `${now.toLocaleDateString(undefined, { weekday: "short" })} ${now.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}`;
    clocks.forEach((c) => (c.textContent = text));
    // The menu bar's pill grows leftward to fit the time ("Sun 1:54 AM" is longer than "Fri 9:41").
    const svgClock = demo.querySelector("text.clock");
    const pill = demo.querySelector(".clock-pill");
    if (svgClock && pill) {
      const shift = Math.min(0, 786 - 14 - (714 + svgClock.getComputedTextLength()));
      pill.setAttribute("x", 640 + shift);
      pill.setAttribute("width", 146 - shift);
      demo.querySelector(".right-items").setAttribute("transform", `translate(${shift} 0)`);
    }
  }
  tellTime();
  document.fonts?.ready.then(tellTime);
  setInterval(tellTime, 15000);

  controls.sync();
  render(reduce.matches ? 20000 : 0);
  sync();

  // Feature tiles draw their little pictures once they scroll into view.
  const seen = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("seen");
      seen.unobserve(entry.target);
    }
  }, { threshold: 0.35 });
  document.querySelectorAll(".tile").forEach((el) => seen.observe(el));
})();
