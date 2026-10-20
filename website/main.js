// One clock drives speech, ink, cursor, levels and handoff. No dependencies.
(() => {
  const demo = document.querySelector("#demo");
  const pens = [...demo.querySelectorAll(".pen")];
  const cursor = demo.querySelector(".cursor");
  const meter = [...demo.querySelectorAll(".meter i")];
  // On phones the screen runs past both edges (135% wide), and the window runs off them too:
  // its content fills the visible middle, and its sides and bottom are cropped, like the video.
  if (matchMedia("(max-width: 600px)").matches) {
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
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  // ?t=7000 holds the demo at that moment (for screenshots).
  const still = new URLSearchParams(location.search).get("t");

  // The script: what's said when, and when each mark appears.
  const T = {
    circle: [5000, 5600], // the badge that overlaps the number
    box: [7200, 7800], // the broken image
    arrow: [10200, 10800], // the tooltip the chart cuts off
    tip: 9300, // the cursor hovers the chart: its tooltip shows
    pen: 3700, // the pen is picked up: the cursor stays a pen until you stop
    stop: 15600,
    stopped: 15900,
    done: 18200,
    connect: [18400, 19000],
    pasted: 19000,
    leave: 27000, // the pill and card collapse, the marks and caption fade: a clean screen to restart on
    duration: 28500,
  };
  // What you say, and when. While you talk, the toolbar grows a line and your words stream into it.
  // Each window is when that sentence may be said; "|" is a breath between phrases.
  const speech = [
    [400, 4700, "Okay so | I want you to fix a few issues here on my website"],
    [4800, 7000, "This badge overlaps the number"],
    [7100, 9500, "the image here is broken"],
    [9600, 12000, "and the tooltip on the graph | gets cut off"],
    [12600, 15400, "Fix it all please | and yeah | make no mistakes"],
  ];
  // Words come at a talking pace, not spread evenly over the window: a long word takes longer
  // than a short one, a breath leaves a gap, and each word shows once it's been said.
  const said = demo.querySelector(".toolbar .said");
  const lines = speech.map(([from, to, text]) => {
    const line = document.createElement("span");
    line.className = "line";
    let t = 0;
    const timed = [];
    for (const word of text.split(" ")) {
      if (word === "|") {
        t += 260;
        continue;
      }
      t += 60 + 42 * word.length;
      timed.push([word, t]);
    }
    const squeeze = Math.min(1, (to - from) / t);
    const spans = timed.map(([word, at]) => {
      const span = document.createElement("span");
      span.textContent = word;
      span.dataset.t = from + at * squeeze;
      return span;
    });
    line.append(...spans);
    said.append(line);
    return { line, spans, from, to: from + t * squeeze };
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
    if (ms < T.circle[0]) return between({ x: 440, y: 300 }, along(0, 0), (ms - 3700) / 1200);
    if (ms < T.circle[1]) return along(0, progress(ms, T.circle));
    if (ms < T.box[0]) return between(along(0, 1), along(1, 0), (ms - 5800) / 1300);
    if (ms < T.box[1]) return along(1, progress(ms, T.box));
    if (ms < T.arrow[0]) {
      return ms < T.tip ? between(along(1, 1), hover, (ms - 7900) / 1200) : between(hover, along(2, 0), (ms - 9600) / 600);
    }
    if (ms < T.arrow[1]) return along(2, progress(ms, T.arrow));
    return along(2, 1);
  }

  function render(ms) {
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
      (within(ms, [T.connect[0], T.connect[0] + 450]) ? " copying" : "") +
      (within(ms, [T.stop, T.stopped]) ? " stopping" : "") +
      (done ? " finished" : "") +
      (ms >= T.pasted ? " pasted" : "") +
      (ms >= T.leave ? " leaving" : "");

    const speaking = recording && lines.some(({ from, to }) => ms >= from && ms < to + 150);
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
    meter.forEach((bar, i) => {
      const level = !recording ? 0.15 : speaking ? 0.3 + Math.abs(Math.sin(ms / 160 + i * 1.7)) * 0.7 : 0.18 + Math.abs(Math.sin(ms / 400 + i)) * 0.1;
      bar.style.transform = `scaleY(${level.toFixed(3)})`;
    });

    strokes.forEach((w, i) => {
      const drawn = progress(ms, w);
      pens[i].style.strokeDashoffset = lengths[i] * (1 - drawn);
      pens[i].style.visibility = drawn > 0 ? "visible" : "hidden"; // a round cap would show as a dot
    });

    const p = pointer(ms);
    cursor.setAttribute("transform", `translate(${p.x.toFixed(2)} ${p.y.toFixed(2)})`);
    timer.textContent = "00:" + String(Math.min(15, Math.floor(ms / 1000))).padStart(2, "0");

    toolbar.setAttribute("aria-hidden", String(!done));
    output.setAttribute("aria-hidden", String(ms < T.pasted));
  }

  function tick(now) {
    if (last) elapsed = (elapsed + now - last) % T.duration;
    last = now;
    render(elapsed);
    frame = requestAnimationFrame(tick);
  }
  // It waits on its first frame until the screen is mostly in view and the scrolling has settled, then
  // plays from the top. Scroll away and it rests; scroll back and it plays from the top again.
  const PLAY_AT = 0.6, REST_BELOW = 0.2, SETTLE = 350;
  let ratio = 0,
    playing = false,
    arming = 0,
    lastScroll = performance.now();
  addEventListener("scroll", () => (lastScroll = performance.now()), { passive: true });
  const canPlay = () => still === null && !reduce.matches && !document.hidden;
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
  }
  function rest(reset) {
    cancelAnimationFrame(frame);
    clearTimeout(arming);
    arming = 0;
    playing = false;
    last = 0;
    if (reset && canPlay()) {
      elapsed = 0;
      render(0);
    }
  }
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
      render(+still);
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
    scene.style.setProperty("--k", width > 600 ? ((width / 800) * 0.74).toFixed(3) : 1);
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
