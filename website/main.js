// One clock drives speech, ink, cursor, levels and handoff. No dependencies.
(() => {
  const demo = document.querySelector("#demo");
  const pens = [...demo.querySelectorAll(".pen")];
  const cursor = demo.querySelector(".cursor");
  const meter = [...demo.querySelectorAll(".meter i")];
  // On phones the screen runs past both edges, but the window keeps its size: scaled down by
  // as much as the screen is scaled up (135%), so it stays in view.
  if (matchMedia("(max-width: 600px)").matches) {
    demo.querySelectorAll("[transform='translate(400 214) scale(0.88) translate(-400 -199)']").forEach((g) =>
      g.setAttribute("transform", "translate(400 222) scale(0.66) translate(-400 -199)"),
    );
  }
  // The window sits on the wallpaper (moved and scaled): marks and the cursor live in its coordinates.
  const desk = demo.querySelector(".desk").transform.baseVal.consolidate().matrix;
  const onDesk = (p) => new DOMPoint(p.x, p.y).matrixTransform(desk.inverse());
  const timer = demo.querySelector(".timer");
  const scene = demo.querySelector(".scene");
  const toolbar = demo.querySelector(".toolbar");
  const output = demo.querySelector(".output");
  const connector = demo.querySelector(".connector");
  const [reveal, dots] = connector.querySelectorAll("path");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  // ?t=7000 holds the demo at that moment (for screenshots).
  const still = new URLSearchParams(location.search).get("t");

  // The script: what's said when, and when each mark appears.
  const T = {
    circle: [1900, 3600],
    box: [5300, 7300],
    arrow: [9300, 10150],
    head: [10200, 10500],
    stop: 12200,
    stopped: 12500,
    done: 14800,
    connect: [15000, 15600],
    pasted: 15600,
    leave: 25600, // the pill and card collapse, the marks and caption fade: a clean screen to restart on
    duration: 27000,
  };
  // What you say, and when. While you talk, the toolbar grows a line and your words stream into it.
  // Each window is when that sentence may be said; "|" is a breath between phrases.
  const speech = [
    [400, 4400, "As you can see here | these are not centered properly"],
    [5400, 7600, "and this one | should match it"],
    [8800, 10800, "Also | make this button bigger"],
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

  // Where the stop button is, in screen coordinates (the toolbar moves on small screens).
  function stopPoint() {
    const screen = demo.querySelector(".screen").getBoundingClientRect();
    const stop = demo.querySelector(".stop").getBoundingClientRect();
    return onDesk({
      x: ((stop.x + stop.width / 2 - screen.x) * 800) / screen.width,
      y: ((stop.y + stop.height / 2 - screen.y) * 450) / screen.height,
    });
  }

  // Each stroke in order, as one hand would draw them (the arrow's head after its shaft).
  const strokes = [T.circle, T.box, T.arrow, T.head];

  // Where the cursor is: drawing each stroke, and moving between them.
  function pointer(ms) {
    const along = (i, t) => pens[i].getPointAtLength(lengths[i] * t);
    if (ms < T.circle[0]) return between({ x: 440, y: 300 }, along(0, 0), (ms - 900) / 950);
    if (ms < T.circle[1]) return along(0, progress(ms, T.circle));
    if (ms < T.box[0]) return between(along(0, 1), along(1, 0), (ms - 3900) / 1200);
    if (ms < T.box[1]) return along(1, progress(ms, T.box));
    if (ms < T.arrow[0]) return between(along(1, 1), along(2, 0), (ms - 7700) / 1300);
    if (ms < T.arrow[1]) return along(2, progress(ms, T.arrow));
    if (ms < T.head[0]) return between(along(2, 1), along(3, 0), (ms - T.arrow[1]) / (T.head[0] - T.arrow[1]));
    if (ms < T.head[1]) return along(3, progress(ms, T.head));
    return between(along(3, 1), stopPoint(), (ms - 11300) / 800);
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
      (strokes.some((w) => within(ms, w)) || within(ms, [T.arrow[1], T.head[0]]) ? " drawing" : "") +
      (within(ms, [T.stop, T.stopped]) ? " stopping" : "") +
      (done ? " finished" : "") +
      (ms >= T.pasted ? " pasted" : "") +
      (ms >= T.leave ? " leaving" : "");

    const speaking = recording && lines.some(({ from, to }) => ms >= from && ms < to + 150);
    for (const l of lines) {
      l.line.classList.toggle("now", l === now);
      l.spans.forEach((w) => w.classList.toggle("on", ms > +w.dataset.t));
      if (l === now) l.line.classList.toggle("tail", l.line.scrollWidth > said.clientWidth + 1);
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
    timer.textContent = "00:" + String(Math.min(12, Math.floor(ms / 1000))).padStart(2, "0");

    reveal.style.strokeDashoffset = connectorLength * (1 - progress(ms, T.connect));
    toolbar.setAttribute("aria-hidden", String(!done));
    output.setAttribute("aria-hidden", String(ms < T.pasted));
  }

  // A dotted line between the toolbar's pill and the pasted card, drawn as the text moves over:
  // up into the card floating over the screen, or down to it on phones. Both scale from the edge
  // that faces the other, so these points hold while they animate.
  let connectorLength = 0;
  function placeConnector() {
    const box = scene.getBoundingClientRect(),
      bar = toolbar.getBoundingClientRect(),
      card = output.getBoundingClientRect(),
      k = parseFloat(scene.style.getPropertyValue("--k")) || 1;
    const x = bar.x + bar.width / 2 - box.x,
      above = card.bottom <= bar.bottom,
      from = (above ? bar.bottom - 38 * k - 6 : bar.top + 36 + 6) - box.y,
      to = (above ? card.bottom + 6 : card.top - 6) - box.y,
      bend = Math.min(48, Math.abs(to - from) * 0.6);
    const d = `M${x} ${from}C${x + bend} ${from + (to - from) * 0.35} ${x + bend} ${from + (to - from) * 0.7} ${x} ${to}`;
    reveal.setAttribute("d", d);
    dots.setAttribute("d", d);
    connectorLength = dots.getTotalLength();
    reveal.style.strokeDasharray = connectorLength;
  }

  function tick(now) {
    if (last) elapsed = (elapsed + now - last) % T.duration;
    last = now;
    render(elapsed);
    frame = requestAnimationFrame(tick);
  }
  function sync() {
    cancelAnimationFrame(frame);
    last = 0;
    if (still !== null) {
      document.documentElement.classList.add("still");
      render(+still);
    } else if (reduce.matches) {
      render(20000);
      demo.classList.remove("animated");
    } else if (visible && !document.hidden) {
      frame = requestAnimationFrame(tick);
    }
  }
  // The toolbar is drawn at the screen's 800-wide scale; grow it with the screen (a little
  // smaller than the screen's own scale; phones have their own compact layout).
  new ResizeObserver(([entry]) => {
    const width = entry.contentRect.width;
    scene.style.setProperty("--k", width > 600 ? ((width / 800) * 0.74).toFixed(3) : 1);
    placeConnector();
  }).observe(scene);
  document.addEventListener("visibilitychange", sync);
  reduce.addEventListener("change", sync);
  // It plays once the screen is mostly in view (from the start, on its first frame until then),
  // and pauses when scrolled away.
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    sync();
  }, { threshold: 0.5 }).observe(scene);
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

  placeConnector();
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
  document.querySelectorAll(".tile, .terminal").forEach((el) => seen.observe(el));
})();
