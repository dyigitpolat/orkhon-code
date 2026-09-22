#!/usr/bin/env python3
"""Generate Lumen's registry from the vendored SciTE and Lexilla sources.

Run from any directory; no downloads or third-party Python packages are needed.
Keyword strings are Scintilla word lists: array index 0 is SciTE `keywords`,
index 1 is `keywords2`, etc. Empty slots MUST remain in place. Extensions have
no leading dot and can be compound (e.g. cmake.in). Filenames are literals.
Only lexer options, not editor commands/styles, are exported as properties.

SciTE supplies the profiles, shared word lists and file associations. Lexilla's
registered LexerModules validate names, and its TOML/Nix/Dart example configs
provide additional word lists. Curated entries below contain only aliases,
display names and dialect options, never hand-maintained syntax vocabularies.
See Vendor/scite/License.txt and Vendor/lexilla/License.txt for upstream terms.
"""

from __future__ import annotations

import argparse
from copy import deepcopy
from dataclasses import dataclass, field
import fnmatch
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
# Some upstream text/assembly filters include binary formats. Never register them.
BINARY_EXTENSIONS = frozenset("""
out a o obj exe dll so dylib lib bin dat class pyc pyo wasm pdf rtf doc docx
xls xlsx ppt pptx odt ods odp zip gz bz2 xz zst 7z rar tar tgz dmg iso pkg
png jpg jpeg gif webp ico icns tiff tif bmp heic mp3 mp4 m4a mov avi wav flac
woff woff2 ttf otf eot sqlite sqlite3 db pdb pch
""".split())
# Valid text profiles can still have unsafe system-wide associations: Outlook
# messages, MySQL table definitions and generic database indexes are binary.
# Keep detection/manual profiles, but do not advertise these to Launch Services.
# .ts is deliberately TypeScript; the installer should declare a source-code UTI
# instead of inheriting the MPEG transport-stream UTI for that extension.
UNSAFE_INSTALLER_EXTENSIONS = BINARY_EXTENSIONS | {"msg", "frm", "idx"}
GENERIC_FILES = {"SciTE", "SciTEGlobal", "Embedded", "abbrev"}
VARIABLE = re.compile(r"\$\(([^()]*)\)")
EXTENSION = re.compile(r"\*\.([\w+.-]+)\Z")
PLATFORM = {"PLAT_MAC": "1", "PLAT_WIN": "0", "PLAT_WINNT": "0", "PLAT_GTK": "0"}
DISPLAY_NAMES = {
    "cpp": "C / C++", "cs": "C#", "js": "JavaScript", "html": "HTML",
    "xml": "XML", "vxml": "VoiceXML", "docbook": "DocBook", "py": "Python",
    "rb": "Ruby", "bash": "Shell", "awk": "AWK", "props": "Properties",
    "make": "Makefile", "diff": "Diff", "test": "C-like text", "rc": "Windows Resource",
    "idl": "IDL", "flash": "ActionScript", "ch": "Ch", "asl": "ASL",
    "f77": "Fortran 77", "f95": "Fortran", "m3": "Modula-3", "sml": "Standard ML",
    "caml": "OCaml", "scons": "SCons", "wscript": "VBScript", "vb": "Visual Basic",
    "as": "Assembly (GNU)", "asm": "Assembly (NASM)", "hql": "HiveQL",
    "plsql": "PL/SQL", "pig": "Pig", "itcl": "Incr Tcl", "context": "ConTeXt",
    "tex": "TeX", "latex": "LaTeX", "metafun": "MetaFun", "srec": "S-Record",
    "ihex": "Intel HEX", "tehex": "Tektronix HEX", "nncron": "nnCron",
    "json": "JSON", "yaml": "YAML", "sql": "SQL", "css": "CSS", "ps": "PostScript",
    "swift": "Swift", "rust": "Rust", "go": "Go", "java": "Java", "vala": "Vala",
    "pike": "Pike", "meson": "Meson", "cmake": "CMake", "fsharp": "F#",
    "dataflex.all": "DataFlex", "pascal.all": "Pascal", "visualprolog.like": "Visual Prolog",
}


def read_text(path: Path) -> str:
    # SciTEGlobal includes a historical Latin-1 chars.accented value.
    data = path.read_bytes()
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return data.decode("latin-1")


def expand(value: str, values: dict[str, str], chain: tuple[str, ...] = ()) -> str:
    """Expand nested/shared $(variables); missing and cyclic references are empty.

    SciTE removes the backslash and newline without inserting whitespace. This
    matters for continued file patterns as well as for word lists.
    """
    def substitute(match: re.Match[str]) -> str:
        key = match[1]
        if key in chain or len(chain) >= 100:
            return ""
        return expand(values.get(key, ""), values, (*chain, key))

    for _ in range(100):
        replaced = VARIABLE.sub(substitute, value)
        if replaced == value:
            return replaced
        value = replaced
    raise ValueError("Property expansion exceeded its limit")


def read_properties(path: Path, inherited: dict[str, str] | None = None,
                    stack: tuple[Path, ...] = ()) -> dict[str, str]:
    """Read assignments, continuations, imports and SciTE's indented `if` blocks.

    import * is handled by the caller in stable filename order. Missing optional
    imports (e.g. ConTeXt's word lists) match SciTE's empty-property behavior.
    """
    if path in stack or not path.is_file():
        return {}
    values = dict(inherited or PLATFORM)
    result: dict[str, str] = {}
    active = True
    text = re.sub(r"\\\r?\n|\\\r", "", read_text(path))
    for line in text.splitlines():
        if not line:
            continue
        if not line[0].isspace():
            active = True
        if line.startswith("if "):
            condition = expand(line[3:].strip(), values)
            active = condition == "1" or expand(values.get(condition, "0"), values) not in ("", "0")
            continue
        if not active or line.lstrip().startswith("#") or line.startswith("module "):
            continue
        if line.startswith("import "):
            name = expand(line[7:].strip(), values)
            if name and name != "*":
                imported = read_properties(path.parent / (name + ".properties"), values, (*stack, path))
                values.update(imported)
                result.update(imported)
            continue
        key, separator, value = line.lstrip().partition("=")
        key = key.rstrip()
        if key:
            result[key] = value if separator else "1"
            values[key] = result[key]
    return result


def lexer_catalog(lexilla: Path) -> dict[str, set[str]]:
    """Return exact CreateLexer names and supported property names from source.

    Intersect definitions with Lexilla.cxx's catalogue, rather than assuming every
    lexer-shaped source file is actually registered in the linked library.
    """
    registered = set(re.findall(r"&\s*(lm\w+)\s*,?", read_text(lexilla / "src/Lexilla.cxx")))
    result = {}
    for path in sorted((lexilla / "lexers").glob("Lex*.cxx")):
        source = read_text(path)
        options = set(re.findall(r'"((?:lexer\.|fold\.|styling\.|tab\.timmy\.|asp\.|html\.|ps\.|nsis\.)[\w.]*)"', source))
        # `fold` is a common lexer property without a dotted suffix.
        options.add("fold")
        for symbol, name in re.findall(r'\bLexerModule\s+(lm\w+)\s*\([^,]+,[^,]+,\s*"([^"]+)"', source):
            if symbol in registered:
                result[name] = options
    if len(result) != len(registered):
        raise ValueError(f"Only resolved {len(result)} of {len(registered)} registered Lexilla modules")
    return result


def patterns(value: str) -> list[str]:
    return [part.strip() for part in value.split(";") if part.strip()]


def associations(pattern: str) -> tuple[list[str], list[str]]:
    match = EXTENSION.fullmatch(pattern)
    if match:
        extension = match[1].lower()
        if extension.rsplit(".", 1)[-1] not in BINARY_EXTENSIONS:
            return [extension], []
    elif not any(character in pattern for character in "*?[]/$\\"):
        if pattern.rsplit(".", 1)[-1].lower() not in BINARY_EXTENSIONS:
            return [], [pattern]
    return [], []


def matching_value(prefix: str, filename: str, values: dict[str, str],
                   rules: dict[str, str] | None = None) -> str:
    # SciTE's GetWild searches raw property keys lexicographically.
    for key in sorted(values if rules is None else rules):
        if key.startswith(prefix):
            suffix = expand(key[len(prefix):], values)
            if not suffix or any(fnmatch.fnmatchcase(filename.lower(), p.lower()) for p in patterns(suffix)):
                return expand(values[key], values)
    return ""


@dataclass
class Profile:
    name: str
    lexer: str
    extensions: list[str]
    filenames: list[str]
    keywords: list[str]
    properties: dict[str, str]
    source: str = field(repr=False)
    key: str = field(repr=False)

    def record(self) -> dict:
        return {"name": self.name, "lexer": self.lexer,
                "extensions": sorted(set(self.extensions)), "filenames": sorted(set(self.filenames)),
                "keywords": self.keywords, "properties": dict(sorted(self.properties.items()))}


def profile_name(key: str, lexer: str, sample: str, local: dict[str, str], values: dict[str, str]) -> str:
    if key in DISPLAY_NAMES:
        return DISPLAY_NAMES[key]
    label = expand(local.get("filter." + key, ""), values).split("|", 1)[0]
    if label:
        return re.sub(r"\s*\([^)]*\)\s*$", "", label).replace("&", "").strip()
    for prop, value in sorted(local.items()):
        if prop.startswith("*language."):
            fields = expand(value, values).split("|")
            if len(fields) > 1 and sample.lower().endswith("." + fields[1].lower()):
                return fields[0].replace("&", "")
    return key.replace("_", " ").title() if key else lexer.title()


def collect_profiles(path: Path, local: dict[str, str], shared: dict[str, str],
                     catalog: dict[str, set[str]]) -> list[Profile]:
    values = {**shared, **local}
    result: list[Profile] = []
    for prop, raw_lexer in sorted(local.items()):
        if not prop.startswith("lexer."):
            continue
        lexer = expand(raw_lexer, values).strip()
        suffix = prop[6:]
        # lexer.foo.option assignments are not language declarations.
        if not ("$(" in suffix or "*" in suffix or lexer in catalog):
            continue
        if lexer not in catalog:
            raise ValueError(f"{path.name}: unavailable Lexilla lexer {lexer!r} for {prop}")
        profile_key = suffix.removeprefix("$(file.patterns.").removesuffix(")") if suffix.startswith("$(file.patterns.") else lexer
        grouped: dict[tuple, Profile] = {}
        for pattern in patterns(expand(suffix, values)):
            exts, names = associations(pattern)
            if not exts and not names:
                continue
            sample = "example." + exts[0] if exts else names[0]
            words = []
            for i in range(1, 10):
                prefix = "keywords" + (str(i) if i > 1 else "") + "."
                # Keep a profile's own vocabulary when several profiles share
                # an extension (notably TeX/LaTeX/ConTeXt).
                direct = prefix + suffix
                word_list = expand(local[direct], values) if direct in local else matching_value(prefix, sample, values, local)
                words.append(" ".join(word_list.split()))
            options = {}
            for option in sorted(catalog[lexer]):
                if option in values:
                    options[option] = expand(values[option], values).strip()
                selected = matching_value(option + ".", sample, values)
                if selected:
                    options[option] = selected.strip()
            signature = (tuple(words), tuple(sorted(options.items())))
            if signature not in grouped:
                name = profile_name(profile_key, lexer, sample, local, values)
                grouped[signature] = Profile(name, lexer, [], [], words, options, path.name, profile_key)
            grouped[signature].extensions.extend(exts)
            grouped[signature].filenames.extend(names)
        # Most declarations are a single profile; retain different keyword sets
        # when one upstream file-pattern group contains multiple dialects.
        for index, profile in enumerate(grouped.values()):
            if index:
                profile.name += " (" + (profile.extensions or profile.filenames)[0] + ")"
            result.append(profile)
    return result


def add_aliases(profiles: list[Profile], catalog: dict[str, set[str]]) -> None:
    def find(key: str) -> Profile:
        return next(profile for profile in profiles if profile.key == key)

    def alias(name: str, base: str, extensions: str, filenames: tuple[str, ...] = (),
              lexer: str | None = None, options: dict[str, str] | None = None) -> Profile:
        profile = deepcopy(find(base))
        profile.name, profile.key = name, name
        profile.extensions, profile.filenames = extensions.split(), list(filenames)
        if lexer:
            if lexer not in catalog:
                raise ValueError(f"Alias {name} requests unavailable lexer {lexer}")
            profile.lexer = lexer
            profile.properties = {k: v for k, v in profile.properties.items() if k in catalog[lexer]}
        profile.properties.update(options or {})
        profiles.append(profile)
        return profile

    find("js").extensions.extend(["cjs", "jsx"])
    alias("TypeScript", "js", "ts tsx mts cts")
    # Swift already has an upstream vocabulary. This Lexilla release uses cpp;
    # upgrade to the native lexer automatically if a future vendor adds it.
    if "swift" in catalog:
        find("swift").lexer = "swift"
    # Kotlin uses Java's upstream word lists until a Kotlin config is vendored.
    alias("Kotlin", "java", "kt kts", lexer="kotlin" if "kotlin" in catalog else "cpp")
    alias("PHP", "html", "php php3 php4 php5 php7 php8 phtml")
    alias("SCSS", "css", "scss", options={"lexer.css.scss.language": "1"})
    alias("Less", "css", "less", options={"lexer.css.less.language": "1"})
    find("bash").extensions.append("zsh")
    find("bash").filenames.extend([".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile"])
    find("rb").filenames.extend(["Gemfile", "Rakefile", "Guardfile", "Vagrantfile", "Podfile", ".irbrc"])
    find("make").filenames.extend(["GNUmakefile", "BSDmakefile"])
    find("props").filenames.extend([".editorconfig", ".gitconfig", ".gitmodules", ".npmrc"])
    find("yaml").filenames.extend([".clang-format", ".clang-tidy"])
    find("json").filenames.extend([".eslintrc", ".jshintrc", ".babelrc", ".prettierrc", ".stylelintrc"])
    find("xml").extensions.extend(["plist", "xib", "storyboard", "entitlements", "xcworkspacedata"])
    find("py").extensions.append("pyi")
    find("markdown").extensions.extend(["mdown", "mkdn"])
    # Plain text has file.patterns.text but no explicit lexer assignment in SciTE.


def normalize(profiles: list[Profile]) -> list[dict]:
    # Merge duplicate declarations without merging distinct language dialects.
    merged: dict[tuple, Profile] = {}
    for profile in profiles:
        signature = (profile.name, profile.lexer, tuple(profile.keywords), tuple(sorted(profile.properties.items())))
        if signature in merged:
            merged[signature].extensions.extend(profile.extensions)
            merged[signature].filenames.extend(profile.filenames)
        else:
            merged[signature] = profile
    profiles = list(merged.values())
    # Explicit precedence for genuinely ambiguous upstream suffixes. Other ties
    # use the raw SciTE declaration key, then source filename (stable on every OS).
    preferred = {"ts": "TypeScript", "tsx": "TypeScript", "php": "PHP", "php3": "PHP", "phtml": "PHP",
                 "m": "cpp", "h": "cpp", "inc": "test", "pl": "perl", "conf": "conf",
                 "tex": "latex", "sty": "latex", "m.octave": "octave", "configure": "bash"}
    for attribute in ("extensions", "filenames"):
        owners: dict[str, list[Profile]] = {}
        for profile in profiles:
            for value in set(getattr(profile, attribute)):
                if value.rsplit(".", 1)[-1].lower() not in BINARY_EXTENSIONS:
                    owners.setdefault(value.lower(), []).append(profile)
        for value, choices in owners.items():
            winner = min(choices, key=lambda p: (p.key != preferred.get(value), p.lexer == "tex" and p.key == "latex", p.key, p.source))
            for profile in choices:
                if profile is not winner:
                    setattr(profile, attribute, [v for v in getattr(profile, attribute) if v.lower() != value])
    names: dict[str, list[Profile]] = {}
    for profile in profiles:
        names.setdefault(profile.name, []).append(profile)
    for duplicates in names.values():
        if len(duplicates) > 1:
            for profile in duplicates:
                same_lexer = sum(p.lexer == profile.lexer for p in duplicates) > 1
                qualifier = ", ".join(profile.extensions or profile.filenames) if same_lexer else profile.lexer
                profile.name += f" ({qualifier})"
    records = sorted((p.record() for p in profiles), key=lambda r: (r["name"].casefold(), r["name"]))
    if len({r["name"] for r in records}) != len(records):
        raise ValueError("Profile names must be unique stable IDs")
    return records


def generate(scite: Path, lexilla: Path) -> tuple[list[dict], dict]:
    catalog = lexer_catalog(lexilla)
    directory = scite / "src"
    paths = [p for p in sorted(directory.glob("*.properties")) if p.stem not in GENERIC_FILES]
    if len(paths) < 80:
        raise ValueError(f"SciTE checkout incomplete: found only {len(paths)} language property files")
    shared = {**PLATFORM, **read_properties(directory / "SciTEGlobal.properties")}
    locals_by_path = {}
    for path in paths:
        local = read_properties(path, shared)
        locals_by_path[path] = local
        shared.update(local)
    profiles = []
    for path, local in locals_by_path.items():
        profiles.extend(collect_profiles(path, local, shared, catalog))
    for name, slots in (("toml", 1), ("nix", 3), ("dart", 3)):
        path = lexilla / "test/examples" / name / "SciTE.properties"
        local = read_properties(path)
        added = collect_profiles(path, local, PLATFORM, catalog)
        for profile in added:
            profile.name = {"toml": "TOML", "nix": "Nix", "dart": "Dart"}[name]
            # Later sets in these test fixtures name sample user-defined symbols.
            profile.keywords[slots:] = [""] * (9 - slots)
            profile.source = "Lexilla/" + name
        profiles.extend(added)
    add_aliases(profiles, catalog)
    text_exts = [ext for pattern in patterns(expand(shared["file.patterns.text"], shared)) for ext in associations(pattern)[0]]
    profiles.append(Profile("Plain Text", "null", text_exts, ["README", "LICENSE", "COPYING", "NOTICE", "AUTHORS", "CHANGELOG"], [""] * 9, {}, "others.properties", "text"))
    # Finder associates final suffixes; retain compound detection while registering their text suffixes.
    for profile in profiles:
        if profile.name == "Matlab": profile.extensions.append("matlab")
        if profile.name == "Octave": profile.extensions.append("octave")
        if profile.name == "Plain Text": profile.extensions.append("in")
    records = normalize(profiles)
    for record in records:
        if record["lexer"] not in catalog or "$(" in json.dumps(record):
            raise ValueError(f"Invalid or unresolved profile: {record['name']}")
        if any(ext.rsplit(".", 1)[-1] in BINARY_EXTENSIONS for ext in record["extensions"]):
            raise ValueError(f"Binary extension in {record['name']}")
    report = {"profiles": len(records), "extensions": len({e for r in records for e in r["extensions"]}),
              "installer_extensions": len(supported_extensions(records)),
              "filenames": len({f for r in records for f in r["filenames"]}),
              "lexers_used": len({r["lexer"] for r in records}), "lexers_available": len(catalog),
              "scite_property_files": len(paths)}
    return records, report


def supported_extensions(records: list[dict]) -> list[str]:
    """Sorted, dotless extension array for the installer (not a UTI mapping)."""
    return sorted({extension for record in records for extension in record["extensions"]
                   if extension.rsplit(".", 1)[-1] not in UNSAFE_INSTALLER_EXTENSIONS})


def revision(directory: Path) -> str:
    # Do not accidentally report Lumen's enclosing repository as upstream's.
    if (directory / ".git").exists():
        result = subprocess.run(["git", "-C", str(directory), "rev-parse", "HEAD"], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    version = directory / "version.txt"
    return "version " + read_text(version).strip() if version.exists() else "vendored snapshot"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scite", type=Path, default=ROOT / "Vendor/scite")
    parser.add_argument("--lexilla", type=Path, default=ROOT / "Vendor/lexilla")
    parser.add_argument("--output", type=Path, default=ROOT / "Resources/languages.json")
    parser.add_argument("--extensions-output", type=Path, default=ROOT / "Resources/supported-extensions.json")
    parser.add_argument("--check", action="store_true", help="Fail if generated resources are missing or stale")
    args = parser.parse_args()
    records, report = generate(args.scite, args.lexilla)
    extensions = supported_extensions(records)
    for path, payload in ((args.output, records), (args.extensions_output, extensions)):
        content = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != content:
                print(f"Stale generated resource: {path}", file=sys.stderr)
                return 1
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    print(json.dumps({**report, "SciTE": revision(args.scite), "Lexilla": revision(args.lexilla)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
