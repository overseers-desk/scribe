# Whisper streaming for continuous dictation

Reference for anyone building a continuous transcription mode (whisper transcribes
during recording, rather than once after it stops). It records what whisper.cpp's
streaming path does and the duplicate-text problem it creates, so the design does
not have to be rediscovered by experiment.

Distilled from empirical notes taken against whisper.cpp (Oct 2025) and
re-verified against the local checkout on 2026-07-11. scribe itself does **not**
stream today: it records to a file, then runs `whisper-cli` once (one-shot). This
document is for the continuous mode tracked in the "front-load whisper" feature
request (issue #4), not for current behaviour.

## The streaming binary

whisper.cpp ships the streaming client as `examples/stream/stream.cpp` (built as
`stream`). It is not part of the default build here — only `whisper-cli` and
`whisper-server` are built — so a continuous mode has to build it, or drive
`whisper-server` in a loop.

## Core behaviour: each pass re-transcribes a sliding window

`stream` keeps a rolling audio buffer of `--length` milliseconds (default 10 s in
the current source; the Oct-2025 tests used `--length 30000`). On each step it
re-runs whisper over the **whole buffer**, not just the newest audio. Confirmed in
`stream.cpp` by the `n_samples_len` / `n_samples_keep` / `pcmf32_old` handling: it
carries forward up to `length` ms of prior audio each iteration.

Consequences:

- **Recording shorter than the window.** Every transcription starts at t0 = 0 and
  contains all earlier text plus any new text. Transcription N is a superset of
  transcription N-1.
- **Recording longer than the window.** Once past `--length`, the oldest audio is
  dropped and the window's start timestamp (t0) advances. Later transcriptions no
  longer contain the earliest text, because that audio is gone.

Observed example (1 s pause mid-sentence, short recording):

```
Transcription 0:  [00:00.000 --> 00:03.960]  Hi, this is a test.
Transcription 1:  [00:00.000 --> 00:06.060]  Hi, this is a test.
                  [00:06.060 --> 00:08.560]  And I paused one second exactly.
```

Transcription 1 repeats all of transcription 0.

## Why it matters: typing each pass duplicates text

Type each transcription verbatim and the output doubles up:

```
1. "This is a test"
2. "This is a test and I paused one second"
Typed result: "This is a test This is a test and I paused one second"
```

A continuous mode has to de-duplicate. Two workable strategies:

- **Prefix diff.** If the new transcription starts with the last one, type only the
  suffix. Simple; assumes the new text always extends the old.
- **Backspace and retype.** Delete the previous transcription's characters, type the
  new one whole. Handles the case where whisper *revises* earlier words (it can), at
  the cost of visible deletion and exact character accounting.

Because the window slides, a robust typist also has to notice when t0 has advanced
(the window moved on) and treat that transcription as independent rather than a
continuation, or it will lose text that scrolled out of the buffer.

## Design fork

- **One-shot `whisper-cli`** (what scribe does now): record to a file, transcribe
  once when recording stops. No duplicate problem, no revision handling. Cost: no
  early feedback, and the transcription latency lands entirely after the user stops
  speaking. A load failure (e.g. VRAM) also surfaces only then.
- **Streaming (`stream` or a `whisper-server` loop)**: early/continuous output and a
  load failure caught at the first pass, at the cost of the de-duplication and
  revision logic above. `whisper-server` keeps the model resident (loaded once),
  which then competes with the chat model for VRAM.

Note `whisper-server` avoids paying the model-load cost per pass, but it is not a
streaming decoder: it transcribes each request whole. True incremental decoding
(the sliding buffer above) is `stream`'s job.
