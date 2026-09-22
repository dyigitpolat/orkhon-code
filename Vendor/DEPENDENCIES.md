# Vendored source provenance

- Scintilla **5.5.2**: https://github.com/mirror/scintilla/tree/rel-5-5-2, commit `a1c86144eed9e3d2187e3a8b391d11ca909f00d2`.
- Lexilla **5.5.3**: official https://www.scintilla.org/lexilla553.tgz release source archive.
- SciTE property configuration: https://github.com/mirror/scite, commit `d166c05a44a7177c2771805267345d37adc1211f`.
- SwiftTerm **1.10.1**: https://github.com/migueldeicaza/SwiftTerm/tree/v1.10.1, commit `5c83a9d214e7354697624c11deb4e488bdcfabad`.

These sources are built locally without modifying their algorithms. SwiftTerm's terminal library is compiled directly as a SwiftPM target, so its unrelated CLI dependency is not downloaded. Third-party license files are retained in each directory and bundled in the application.

Local Cocoa integration patch: `scintilla/cocoa/ScintillaCocoa.mm` keeps the native document view at least as wide as its viewport. Upstream 5.5.2 used the longest line width, leaving the blank area to its right outside the clickable editor. This changes view geometry only; lexer and text-editing algorithms are unchanged. The native bridge suite checks the hit target after narrowing and widening the editor.
