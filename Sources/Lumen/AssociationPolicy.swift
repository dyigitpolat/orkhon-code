import Foundation

struct AssociationPolicy {
    // .cp is an explicit exception: macOS shares it with the C++ source group.
    // It is disclosed in setup and never replaces a specialist app such as Captivate.
    static let sourceExtensions:Set<String> = Set("txt text json jsonc json5 jsonl ndjson toml yaml yml ini cfg config conf properties env editorconfig gitignore gitattributes gitmodules md markdown mdown mkd mdx rst adoc asciidoc tex bib sty cls sql graphql gql proto prisma tf tfvars hcl nix cmake dockerfile make mak gmk mk c h cp c++ h++ cc cpp cxx hpp hh hxx hp ipp tpp inl m mm swift java jav py pyw pyi pyx ipynb rb rbw rake gemspec rs go js jscript javascript mjs cjs jsx cts tsx vue svelte astro css scss sass less kt kts scala sc dart cs csx fs fsx fsi clj cljs cljc ex erl hrl hs lhs lua jl r sh bash zsh fish ps1 psm1 psd1 bat cmd vb vbs php php3 php4 php5 ph3 ph4 phtml pl pm raku rakumod f f77 f90 f95 f03 f08 for ada adb ads pas pp inc asm s groovy gradle zig v sol cl cu cuh xml xsd wsdl xsl xslt csv tsv log diff patch po coffee nim nims vhdl sv svh vh glsl vert frag wgsl".split(separator:" ").map(String.init))
    // Stable Apple/system identifiers: building does not depend on the builder's
    // installed apps, LaunchServices cache, or whether a GUI session is available.
    static let catalog:[String:[String]] = [
        "public.ada-source":["ada","adb","ads"],"public.assembly-source":["asm","s"],
        "public.bash-script":["bash"],"public.c-header":["h"],"public.c-source":["c"],
        "public.c-plus-plus-source":["cpp","cc","cxx","cp","c++"],"public.c-plus-plus-header":["hpp","hh","hxx","h++"],
        "public.fortran-source":["f","for"],"public.fortran-77-source":["f77"],"public.fortran-90-source":["f90"],"public.fortran-95-source":["f95"],
        "public.objective-c-source":["m"],"public.objective-c-plus-plus-source":["mm"],
        "public.pascal-source":["pas"],"public.perl-script":["pl","pm"],
        "public.python-script":["py","pyw"],"public.ruby-script":["rb"],
        "public.shell-script":["sh"],"public.swift-source":["swift"],"public.zsh-script":["zsh"],
        "com.sun.java-source":["java","jav"],"com.netscape.javascript-source":["js","jscript","javascript","mjs"],"public.php-script":["php","php3","php4","php5","ph3","ph4","phtml"],
        "net.daringfireball.markdown":["md"],
        "public.plain-text":["txt","text"],"public.json":["json"],"public.yaml":["yaml","yml"],
        "public.xml":["xml"],"public.css":["css"],"public.make-source":["make","mak","gmk","mk"]
    ]
    // Extension bindings cover formats without a declared UTI (TOML, Rust, Go,
    // JSONC, and many others). Never invent an owning UTI or replace another app's
    // type declaration. macOS resolves and groups actual types at setup time.
    static var additionalExtensions:[String] {
        sourceExtensions.subtracting(Set(catalog.values.flatMap{$0})).sorted()
    }
    // Only these known general-purpose editors may be offered as replaceable defaults.
    static let editors:Set<String> = ["com.apple.textedit","com.apple.dt.xcode","com.microsoft.vscode","com.exafunction.windsurf","com.microsoft.vscodeinsiders","com.sublimetext.3","com.sublimetext.4","com.barebones.bbedit","com.macromates.textmate","com.panic.nova","com.coteditor.coteditor","dev.zed.zed","com.todesktop.230313mzl4w4u92","app.orkhon.editor"]
    static func eligible(extensions:[String], isSource:Bool, current:String?) -> Bool {
        return !extensions.isEmpty && Set(extensions.map{$0.lowercased()}).isSubset(of:sourceExtensions) && isSource && (current == nil || editors.contains(current!.lowercased()))
    }
}
