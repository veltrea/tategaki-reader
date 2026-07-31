# tategaki-reader

**Read this in other languages:** [日本語](README.md)

A macOS (Mac Catalyst) EPUB reader for Japanese vertical writing (*tategaki*), built to render real-world books *sensibly* rather than strictly — with high-quality text-to-speech through VOICEVOX / AivisSpeech.

---

## Why this exists

Ever since EPUB appeared, CJK vertical writing has had remarkably few stable samples or reference implementations. As a result, books have been produced from a patchwork of local conventions and "this seemed to work" techniques. Analyze the markup of EPUBs that are actually shipping and you will find plenty of tags that are simply wrong.

Interpret those books strictly to spec and they do not render well. This reader starts from the opposite premise: **there should be a mode that prioritizes rendering sensibly over rendering correctly.**

It also works in the other direction. Books with broken body tags or CSS are allowed to **visibly fall apart**, which makes it easy to spot what isn't working — a quick sanity-check tool for people producing EPUBs.

## Two rendering modes

### Readability first (`friendly`, default)

Absorbs sloppiness in the EPUB's own markup and moves the result toward what the author expected to see.

- Scales images to fill the page
- Image-only pages (covers, frontispieces, chapter title pages) bypass the engine's column layout, are drawn directly, and are automatically paired into Kindle-style spreads
- Corrects the aspect ratio of SVG-wrapped covers (books squashed by `preserveAspectRatio="none"`)
- Infers missing vertical-writing declarations from EBPAJ-derived class names and the OPF `primary-writing-mode`

I have helped out with Kindle publishing a number of times, and that experience is where this comes from: having a viewer that just *looks reasonable* is worth a lot. For a writer who isn't steeped in EPUB internals, a single unexpected page break is enough to cause worry. **A tool you can hand over while saying "this is a preview — the final appearance varies per platform"** makes that conversation a lot shorter.

### As-is (`raw`)

Turns every correction off and shows exactly what the engine draws from the EPUB's own instructions. Distorted covers and declarations that never took effect show up as-is. Use it to find out where an EPUB you built is actually broken.

Color theme, font size, line height, and user CSS still apply in `raw` mode — those are reading preferences, not interpretations of the EPUB.

## Measurement overlay

The reader can superimpose a ruler and a 16-color bar over the screen. Cells are 10px and encoded by color, so misalignment and overflow are visible *and* readable as numbers.

This was meant to be debug-only, but it turned out to be **remarkably effective in combination with an AI agent**, so the on-screen grid ships in release builds too (toggle it from the reader's top toolbar).

DEBUG builds go further: the same color scheme is injected as a measurement layer into the content WebView, and coordinates can be pulled out as raw numbers through the MCP server described below. That's the one to use when you want an AI to hunt down HTML/CSS defects — it is a great deal faster.

## Text to speech

When I self-published, the best proofreading method I found was **pairing the text with a screen reader**. These days I spend all day staring at screens; I also write fiction as a hobby, and scrutinizing every line by eye before publishing simply isn't realistic. So TTS got a lot of attention here.

- High-quality voices via VOICEVOX / AivisSpeech
- Playback speed and inter-line pause control
- Start reading from wherever you double-click

### A reading dictionary with priority layers

Japanese TTS engines match **shorter words first**, which causes a specific and annoying failure: override the reading of a single character like 斎, and compounds such as 斎藤 get dragged along and mispronounced.

TTS engines' own user dictionaries have no mechanism to control this, so this app implements **its own reading dictionary with per-entry priority layers (1–10)**. Substitution runs from the highest layer down, and text already substituted is left untouched by lower layers. Put 斎藤ひとし on a layer above 斎 and the single-character rule can no longer break it.

Regular-expression substitution (patterns like `第(\d+)話`) is supported as well.

## Separate shelves

A personal library holds books you would rather not show anyone: material entrusted to you for work, books you keep away from family, books that have nothing to do with whoever is watching your screen.

So you can keep **more than one shelf** (File > Switch Shelf). Switching swaps the whole thing: book list, collections, favorites, reading positions, bookmarks, covers, reading dictionary, and shared CSS. Machine-level settings such as the speech engine connection stay shared.

This is deliberately not a "hide the books I don't want seen" feature. Hiding leaks the moment you miss one path — forgetting to turn it back on, a cover left in the in-memory cache, the cover painted behind the shelf. If you switch what the app reads instead, anything it isn't reading cannot be displayed. For screenshots, keep a shelf holding only books you are free to publish.

The EPUB files themselves are shared across shelves, and deleting a shelf never deletes the files.

## Export

- **Per-chapter audio files** — listen to your own novel on the commute, or check a collaborative work in spare moments
- **Read-along video** — exports an MP4 where only the passage being read glows, typeset vertically. No screen recorder, no video editor. Publishing your own work to YouTube becomes far less of a chore

The video generation part is also available standalone as a browser-only tool under [`narration-video/`](narration-video/).

## For developers: end-to-end test automation without computer-use

One of this project's core concepts is **end-to-end automated testing driven through MCP**. If you're interested in GUI test automation, this is a small, working sample you can actually run.

- **No coordinate clicking** — UI elements are located by name through the Accessibility (AX) API. No dependence on eyeballing screenshots, on bringing windows to the front, or on notification banners not covering things
- **In-app command bus** — a JSONL-over-TCP command server is built in ([`TestBus.swift`](spike-readium/Sources/TestBus.swift)). State changes and checks that are awkward to reach through the UI become one-line commands. **Editing and verifying the reading dictionary (`dictAdd` / `applyRules`) is open in release builds too**, so lining up dozens of compounds can be handed to an AI agent (every other command stays DEBUG-only)
- **Assert on numbers** — instead of "it looks off," `ui_overflow` reports "this button overflows the frame by 12.3pt to the right." No visual screenshot comparison
- **A test runs in seconds**

The methodology itself is documented under `docs/`.

- [`docs/layout-qa-methodology.md`](docs/layout-qa-methodology.md) — known-geometry fixtures + programmatic measurement + numeric assertions
- [`docs/measurement-overlay-technique.md`](docs/measurement-overlay-technique.md) — injecting a measurement layer into a WebView
- [`mcp/epub-test-mcp/`](mcp/epub-test-mcp/) — the MCP server itself (Python, no external dependencies)
- [`test-assets/ruler/`](test-assets/ruler/) — a measurement EPUB with scales burned into all four edges

## Download

Prebuilt apps live on the [Releases](https://github.com/veltrea/tategaki-reader/releases) page. Open the DMG and drag `EpubReaderSpike.app` into `Applications` (0.2.0 and earlier shipped as a ZIP).

The app is **ad-hoc signed** — no Apple Developer account ($99/year) involved — so macOS asks you to confirm the first launch.

1. **Right-click → Open** (a double-click will not work), then Open again
2. Or go to System Settings → Privacy & Security → Open Anyway
3. Or, from a terminal:

```bash
xattr -dr com.apple.quarantine /Applications/EpubReaderSpike.app
```

Once allowed, it launches normally from then on: the signature on a released build is fixed, so the permission sticks. The app is not notarized. If you need that, fork it and sign with your own Developer ID.

## Build

Requirements: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
cd spike-readium
xcodegen generate
xcodebuild -project EpubReaderSpike.xcodeproj -scheme EpubReaderSpike \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath ./DerivedData build
open DerivedData/Build/Products/Debug-maccatalyst/EpubReaderSpike.app
```

Start [VOICEVOX](https://voicevox.hiroshiba.jp/) if you want text to speech.

```bash
curl -s http://127.0.0.1:50021/version
```

To use [AivisSpeech](https://aivis-project.com/) instead, point the baseURL in `VoicevoxTTSEngine.Config` at `:10101`.

## Other platforms

Windows and Linux versions are in the works. Stay tuned.

## Project status

This was built for my own use, and some parts are not thoroughly tested. I don't think everything has to be polished to product grade before it can be released — the core features alone should be genuinely useful.

## License

MIT License — see [LICENSE](LICENSE).

For the third-party code bundled here (foliate-js, pdf.js, fflate), see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Contact

Noticed something, or ran into trouble? Open an [issue](../../issues).
