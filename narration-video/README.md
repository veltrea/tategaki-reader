# Narration Video Maker (VOICEVOX + vertical glow)

Type in text, and this tool synthesizes a reading voice with VOICEVOX and produces a
vertical (or horizontal) read-along video where **only the passage being read glows
with a drop shadow** — then saves it as an **MP4 in one click, entirely in the browser**.

It recreates the kinetic-typography / karaoke-subtitle style you often see on YouTube
(text flowing while the current spot lights up), with no screen recorder and no video editor.

## How it works

1. Per line, call VOICEVOX (`:50021`) `audio_query` → derive an **exact speech timeline**
   from mora (consonant/vowel) lengths (no forced alignment) → `synthesis` for the WAV.
2. Typeset vertically on a **Canvas**. The reading position glows as a Gaussian spotlight
   (accent color + `shadowBlur`), the rest is dimmed, and columns scroll right-to-left,
   keeping the active column centered.
3. Recording composites the canvas video via `canvas.captureStream()` with `AudioContext`
   audio through `MediaRecorder`, downloading **MP4 (H.264+AAC)** — automatically falling
   back to WebM where MP4 is unsupported.

## Usage

Prerequisite: VOICEVOX running (default `http://127.0.0.1:50021`).

```bash
cd narration-video
node serve.mjs         # open http://localhost:8123/
```

Then in the browser:

1. Enter text (**newline = new line, blank line = pause**)
2. Pick speaker / orientation (vertical or horizontal) / font size / colors (bg/text/glow = theme)
3. **① Generate audio + timeline** → **② Preview** → **③ Record & save MP4**

> ⚠ Recording happens in real time (a 5-minute reading takes 5 minutes to record). Keep the tab in front while recording.

## Vertical punctuation handling

Canvas has no vertical typesetting, so each character is placed in a cell and drawn
according to its class (`lib/verticalText.mjs`):

- Punctuation `、。，．` → shifted to the cell's top-right (upright)
- Long vowel / dashes / tilde / brackets `ー―（）「」『』【】〜` → rotated 90°
- Small kana `ぁぃっゃゅょ…` → slight top-right offset
- Line-start restriction (kinsoku): leading punctuation hangs onto the previous column

## Layout (testability-first)

Logic is decoupled from DOM/HTTP and runnable under node.

| File | Role | Depends on |
|---|---|---|
| `lib/voicevox.mjs` | Timeline math (fetch injected via DI) | pure JS |
| `lib/verticalText.mjs` | Vertical classification / wrapping / kinsoku | pure JS |
| `lib/render.mjs` | Canvas layout / glow drawing | Canvas 2D |
| `lib/audio.mjs` | WAV decode & concat / playback | AudioContext |
| `lib/vvClient.mjs` | Browser VOICEVOX fetch | fetch |
| `app.mjs` / `index.html` | UI glue | — |
| `serve.mjs` | Zero-dep static server | node |

Tests:

```bash
node lib/timeline.test.mjs   # pure logic + live VOICEVOX integration
```

Japanese: [README.ja.md](README.ja.md).
