# Third-Party Notices

This project bundles the following third-party software. Each component remains
under its own license; the notices below are provided to satisfy those licenses.

---

## foliate-js

The EPUB rendering engine. Bundled under
`spike-readium/Resources/foliate/foliate-js/`.

- Upstream: https://github.com/johnfactotum/foliate-js
- License: MIT
- Copyright (c) 2022 John Factotum
- Full text: [`spike-readium/Resources/foliate/foliate-js/LICENSE`](spike-readium/Resources/foliate/foliate-js/LICENSE)

foliate-js in turn bundles the libraries listed below, which are redistributed
here as part of it.

### PDF.js

Bundled under `spike-readium/Resources/foliate/foliate-js/vendor/pdfjs/`
(`pdf.mjs`, `pdf.worker.mjs`, CSS, CMaps and standard fonts).

- Upstream: https://github.com/mozilla/pdf.js
- License: Apache License 2.0
- Copyright Mozilla Foundation and contributors
- Full text: https://www.apache.org/licenses/LICENSE-2.0

The CMap data under `vendor/pdfjs/cmaps/` is copyright Adobe Systems
Incorporated and redistributed under the terms stated in
[`vendor/pdfjs/cmaps/LICENSE`](spike-readium/Resources/foliate/foliate-js/vendor/pdfjs/cmaps/LICENSE).

The standard fonts under `vendor/pdfjs/standard_fonts/` are covered by
[`LICENSE_LIBERATION`](spike-readium/Resources/foliate/foliate-js/vendor/pdfjs/standard_fonts/LICENSE_LIBERATION)
(Liberation Fonts) and
[`LICENSE_FOXIT`](spike-readium/Resources/foliate/foliate-js/vendor/pdfjs/standard_fonts/LICENSE_FOXIT)
(Foxit fonts).

### fflate

Bundled as `spike-readium/Resources/foliate/foliate-js/vendor/fflate.js`.

- Upstream: https://github.com/101arrowz/fflate
- License: MIT
- Copyright (c) 2020 Arjun Barrett
- Full text: https://github.com/101arrowz/fflate/blob/master/LICENSE

### zip.js

Bundled as `spike-readium/Resources/foliate/foliate-js/vendor/zip.js`.

- Upstream: https://github.com/gildas-lormeau/zip.js
- License: BSD 3-Clause
- Copyright (c) 2022 Gildas Lormeau
- Full text: https://github.com/gildas-lormeau/zip.js/blob/master/LICENSE

---

## Runtime dependencies (not bundled)

These are not redistributed with this project; they are separate applications
the user installs and runs themselves.

- **VOICEVOX** — https://voicevox.hiroshiba.jp/ — used over its local HTTP API
  (`127.0.0.1:50021`). Terms of use for the software and for each voice library
  are defined by their respective providers.
- **AivisSpeech** — https://aivis-project.com/ — used over its local HTTP API
  (`127.0.0.1:10101`), same arrangement.

Audio and video produced through these engines is subject to the terms of the
voice library you used. Check the provider's terms before publishing.
