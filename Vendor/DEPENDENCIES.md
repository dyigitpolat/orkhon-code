# Vendored source provenance

- Scintilla **5.5.2**: https://github.com/mirror/scintilla/tree/rel-5-5-2, commit `a1c86144eed9e3d2187e3a8b391d11ca909f00d2`.
- Lexilla **5.5.3**: official https://www.scintilla.org/lexilla553.tgz release source archive.
- SciTE property configuration: https://github.com/mirror/scite, commit `d166c05a44a7177c2771805267345d37adc1211f`.
- SwiftTerm **1.10.1**: https://github.com/migueldeicaza/SwiftTerm/tree/v1.10.1, commit `5c83a9d214e7354697624c11deb4e488bdcfabad`.

These sources are built locally without modifying their algorithms. SwiftTerm's terminal library is compiled directly as a SwiftPM target, so its unrelated CLI dependency is not downloaded. Third-party license files are retained in each directory and bundled in the application.

Local Cocoa integration patch: `scintilla/cocoa/ScintillaCocoa.mm` keeps the native document view at least as wide as its viewport. Upstream 5.5.2 used the longest line width, leaving the blank area to its right outside the clickable editor. This changes view geometry only; lexer and text-editing algorithms are unchanged. The native bridge suite checks the hit target after narrowing and widening the editor.

## Markdown preview

The renderer assets in `Resources/MarkdownPreview` are built from pinned npm packages. Normal app builds do not install npm packages or run JavaScript build tools.

- [markdown-it](https://github.com/markdown-it/markdown-it) **15.0.2** — MIT; CommonMark, tables, strikethrough and autolinks.
- [markdown-it-task-lists](https://github.com/revin/markdown-it-task-lists) **2.1.1** — ISC; task checkboxes.
- [markdown-it-texmath](https://github.com/goessner/markdown-it-texmath) **1.0.0** — MIT; established TeX delimiter/token rules. An explicit renderer defers actual math rendering.
- [DOMPurify](https://github.com/cure53/DOMPurify) **3.4.15** — Apache-2.0 or MPL-2.0; HTML/SVG sanitization.
- [KaTeX](https://github.com/KaTeX/KaTeX) **0.18.7** — MIT; optional formula renderer and WOFF2 fonts.
- [Mermaid](https://github.com/mermaid-js/mermaid) **11.17.2** — MIT; optional diagram renderer. The 11.x browser bundle avoids adopting Mermaid 12's newer browser floor and default ELK dependency.
- [esbuild](https://github.com/evanw/esbuild) **0.25.12** — MIT; maintainer-only build tool.

Exact dependency trees and npm integrity hashes are in `scripts/markdown-preview/package-lock.json`. Asset checksums are in `MarkdownPreview/SHA256.json`; direct and transitive license notices are in `MarkdownPreview/Licenses`. Browser assets are minified without source maps; only modern WOFF2 math fonts are shipped. The core has no KaTeX or Mermaid code: each optional renderer loads only when its syntax occurs in a requested preview.
