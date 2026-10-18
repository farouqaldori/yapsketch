//! yapsketch-asr: live transcription helper for YapSketch.
//!
//! Runs a streaming transcribe.cpp model (e.g. Parakeet Unified) over audio piped in on stdin and reports text as JSON lines.
//!
//!     yapsketch-asr <streaming-model.gguf>             live mode
//!     yapsketch-asr --offline <model.gguf>             whole-recording mode
//!
//! stdin:  raw 16 kHz mono f32 little-endian PCM. EOF ends the session.
//! stdout: {"type":"ready"}
//!         {"type":"partial","text":"…"}                       caption text (committed + tentative)
//!         {"type":"segment","text":"…","start_ms":0,"end_ms":0}  a finished sentence
//!         {"type":"error","message":"…"}
//!
//! Offline mode reads all of stdin, then prints one line:
//!         {"type":"words","words":[{"t0_ms":0,"t1_ms":0,"text":"…"}]}

use std::io::{self, BufWriter, Read, Write};

use serde_json::json;
use transcribe_cpp::{
    CommitPolicy, Model, ParakeetBufferedStreamOptions, RunOptions, StreamExtension, StreamOptions,
};

const CHUNK_SAMPLES: usize = 1600; // 100 ms at 16 kHz
/// Start a fresh stream after this much audio (at a sentence boundary) to keep state bounded.
const ROTATE_AFTER_MS: i64 = 90_000;

fn emit(out: &mut impl Write, value: serde_json::Value) {
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

/// Index just past the last sentence-ending punctuation in `s`, if any.
fn last_sentence_end(s: &str) -> Option<usize> {
    s.char_indices()
        .filter(|(_, c)| matches!(c, '.' | '?' | '!'))
        .map(|(i, c)| i + c.len_utf8())
        .last()
}

/// Longest piece handed to the model in one run, in samples. Long recordings are
/// cut at the quietest point near each boundary so words aren't split.
const OFFLINE_WINDOW_MS: i64 = 120_000;

fn offline(model_path: &str, out: &mut impl Write) -> i32 {
    let mut bytes = Vec::new();
    if io::stdin().lock().read_to_end(&mut bytes).is_err() {
        emit(
            out,
            json!({"type": "error", "message": "failed to read audio"}),
        );
        return 1;
    }
    let pcm: Vec<f32> = bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect();
    let mut session = match Model::load(model_path).and_then(|m| m.session()) {
        Ok(s) => s,
        Err(e) => {
            emit(
                out,
                json!({"type": "error", "message": format!("load failed: {e}")}),
            );
            return 1;
        }
    };
    let limit_ms = session
        .limits()
        .map(|l| l.effective_max_audio_ms)
        .unwrap_or(0);
    let window_ms = if limit_ms > 0 {
        (limit_ms - 1_000).min(OFFLINE_WINDOW_MS)
    } else {
        OFFLINE_WINDOW_MS
    };
    let window = (window_ms as usize) * 16;

    let run = RunOptions::default();
    let mut words = Vec::new();
    let mut start = 0usize;
    while start < pcm.len() {
        let end = if pcm.len() - start <= window {
            pcm.len()
        } else {
            quietest_cut(&pcm, start + window - 3 * 16_000, start + window)
        };
        match session.run(&pcm[start..end], &run) {
            Ok(t) => {
                let offset = (start / 16) as i64;
                for w in t.words {
                    let text = w.text.trim();
                    if !text.is_empty() {
                        words.push(json!({"t0_ms": offset + w.t0_ms, "t1_ms": offset + w.t1_ms, "text": text}));
                    }
                }
            }
            Err(e) => emit(
                out,
                json!({"type": "error", "message": format!("run failed: {e}")}),
            ),
        }
        start = end;
    }
    emit(out, json!({"type": "words", "words": words}));
    0
}

/// Sample index of the quietest 20 ms frame in `[from, to)`.
fn quietest_cut(pcm: &[f32], from: usize, to: usize) -> usize {
    const FRAME: usize = 320;
    let mut best = (f32::MAX, to);
    let mut i = from;
    while i + FRAME <= to.min(pcm.len()) {
        let energy: f32 = pcm[i..i + FRAME].iter().map(|x| x * x).sum();
        if energy < best.0 {
            best = (energy, i + FRAME / 2);
        }
        i += FRAME;
    }
    best.1
}

/// Latency knob for Parakeet Unified's chunked streaming, as "left,chunk,right" in ms
/// (YAPSKETCH_ASR_CONTEXT). The model default is 5600,1040,1040: about 2 s before text appears.
fn stream_extension() -> Option<StreamExtension> {
    let spec = std::env::var("YAPSKETCH_ASR_CONTEXT").ok()?;
    let v: Vec<i32> = spec
        .split(',')
        .filter_map(|x| x.trim().parse().ok())
        .collect();
    if v.len() != 3 {
        return None;
    }
    Some(StreamExtension::ParakeetBuffered(
        ParakeetBufferedStreamOptions {
            left_ms: Some(v[0]),
            chunk_ms: Some(v[1]),
            right_ms: Some(v[2]),
        },
    ))
}

fn main() {
    // Exit only after `run` returns: the model and Metal device must be dropped first,
    // or ggml aborts while tearing down its GPU state at process exit.
    let code = {
        let stdout = io::stdout();
        let mut out = BufWriter::new(stdout.lock());
        run(&mut out)
    };
    std::process::exit(code);
}

fn run(out: &mut impl Write) -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--offline") {
        let Some(path) = args.get(1) else {
            emit(
                out,
                json!({"type": "error", "message": "usage: yapsketch-asr --offline <model.gguf>"}),
            );
            return 2;
        };
        return offline(path, out);
    }
    let Some(model_path) = args.first().cloned() else {
        emit(
            out,
            json!({"type": "error", "message": "usage: yapsketch-asr <model.gguf>"}),
        );
        return 2;
    };
    let model = match Model::load(&model_path) {
        Ok(m) => m,
        Err(e) => {
            emit(
                out,
                json!({"type": "error", "message": format!("load failed: {e}")}),
            );
            return 1;
        }
    };
    match model.capabilities() {
        Ok(c) if c.supports_streaming => {}
        _ => {
            emit(
                out,
                json!({"type": "error", "message": "model does not support streaming"}),
            );
            return 1;
        }
    }
    let mut session = match model.session() {
        Ok(s) => s,
        Err(e) => {
            emit(
                out,
                json!({"type": "error", "message": format!("session failed: {e}")}),
            );
            return 1;
        }
    };
    emit(out, json!({"type": "ready"}));

    let run = RunOptions::default();
    let mut opts = StreamOptions {
        commit_policy: CommitPolicy::Auto,
        family: stream_extension(),
        ..Default::default()
    };
    if opts.family.is_some() && session.stream(&run, &opts).is_err() {
        eprintln!("latency setting rejected by this model; using its default");
        opts.family = None;
    }
    let mut stdin = io::stdin().lock();
    let mut bytes = vec![0u8; CHUNK_SAMPLES * 4];
    let mut pcm = Vec::with_capacity(CHUNK_SAMPLES);

    // Audio time (ms since the helper started) where the current stream began.
    let mut stream_offset_ms: i64 = 0;
    let mut eof = false;

    while !eof {
        let mut stream = match session.stream(&run, &opts) {
            Ok(s) => s,
            Err(e) => {
                emit(
                    out,
                    json!({"type": "error", "message": format!("stream failed: {e}")}),
                );
                return 1;
            }
        };
        // Bytes of committed text already reported as segments, and when that segment began.
        let mut reported = 0usize;
        let mut seg_start_ms = stream_offset_ms;
        let mut last_partial = String::new();
        let mut received_ms: i64 = 0;

        loop {
            // Read one chunk (or whatever is left before EOF).
            let mut filled = 0;
            while filled < bytes.len() {
                match stdin.read(&mut bytes[filled..]) {
                    Ok(0) => {
                        eof = true;
                        break;
                    }
                    Ok(n) => filled += n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => {
                        eof = true;
                        break;
                    }
                }
            }
            let samples = filled / 4;
            let update = if samples > 0 {
                pcm.clear();
                pcm.extend(
                    bytes[..samples * 4]
                        .chunks_exact(4)
                        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])),
                );
                stream.feed(&pcm)
            } else {
                stream.finalize()
            };
            let update = match update {
                Ok(u) => u,
                Err(e) => {
                    emit(
                        out,
                        json!({"type": "error", "message": format!("feed failed: {e}")}),
                    );
                    break;
                }
            };
            received_ms = update.input_received_ms;
            let now_ms = stream_offset_ms + received_ms;

            let text = stream.text();
            let display = text.display();
            if display != last_partial {
                emit(out, json!({"type": "partial", "text": display.trim()}));
                last_partial = display;
            }

            // Report finished sentences out of the committed (append-only) text.
            let committed = &text.committed;
            let finished = if samples == 0 {
                Some(committed.len())
            } else {
                last_sentence_end(committed)
            };
            if let Some(end) = finished {
                if end > reported
                    && committed.is_char_boundary(reported)
                    && committed.is_char_boundary(end)
                {
                    let sentence = committed[reported..end].trim();
                    if !sentence.is_empty() {
                        emit(
                            out,
                            json!({"type": "segment", "text": sentence, "start_ms": seg_start_ms, "end_ms": now_ms}),
                        );
                    }
                    reported = end;
                    seg_start_ms = now_ms;
                }
            }

            if samples == 0 {
                break; // finalized at EOF
            }
            // Rotate at a clean point: everything committed has been reported, nothing tentative.
            if received_ms > ROTATE_AFTER_MS
                && reported >= committed.len()
                && text.tentative.trim().is_empty()
            {
                break;
            }
        }
        stream_offset_ms += received_ms;
    }
    0
}
