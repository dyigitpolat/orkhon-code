import Foundation

struct AssociationPolicy {
    // .cp is an explicit exception: macOS shares it with the C++ source group.
    // It is disclosed in setup and never replaces a specialist app such as Captivate.
    static let sourceExtensions:Set<String> = ["cp","c","h","c++","h++","cc","cpp","cxx","hpp","hh","hxx","hp","ipp","m","mm","swift","java","jav","py","pyw","rb","rbw","rs","go","js","jscript","javascript","mjs","jsx","tsx","kt","kts","scala","sc","lua","sh","bash","zsh","fish","php","php3","php4","php5","ph3","ph4","phtml","pl","pm","f","f77","f90","f95","for","ada","adb","ads","pas","pp","inc","asm","s","md"]
    // Stable Apple/system identifiers: building does not depend on the builder's
    // installed apps, LaunchServices cache, or whether a GUI session is available.
    static let catalog:[String:[String]] = [
        "public.ada-source":["ada","adb","ads"],"public.assembly-source":["asm","s"],
        "public.bash-script":["bash"],"public.c-header":["h"],"public.c-source":["c"],
        "public.c-plus-plus-source":["cpp","cc","cxx","cp","c++"],"public.c-plus-plus-header":["hpp","hh","hxx","h++"],
        "public.fortran-source":["f","for"],"public.fortran-77-source":["f77"],"public.fortran-90-source":["f90"],"public.fortran-95-source":["f95"],
        "public.objective-c-source":["m"],"public.objective-c-plus-plus-source":["mm"],
        "public.pascal-source":["pas","p","pp"],"public.perl-script":["pl","pm"],
        "public.python-script":["py","pyw"],"public.ruby-script":["rb"],
        "public.shell-script":["sh"],"public.swift-source":["swift"],"public.zsh-script":["zsh"],
        "com.sun.java-source":["java","jav"],"com.netscape.javascript-source":["js","jscript","javascript","mjs"],"public.php-script":["php","php3","php4","php5","ph3","ph4","phtml"],
        "net.daringfireball.markdown":["md"]
    ]
    // Only these known general-purpose editors may be offered as replaceable defaults.
    static let editors:Set<String> = ["com.apple.textedit","com.apple.dt.xcode","com.microsoft.vscode","com.exafunction.windsurf","com.microsoft.vscodeinsiders","com.sublimetext.3","com.sublimetext.4","com.barebones.bbedit","com.macromates.textmate","com.panic.nova","com.coteditor.coteditor","dev.zed.zed","com.todesktop.230313mzl4w4u92","app.orkhon.editor"]
    static func eligible(extensions:[String], isSource:Bool, current:String?) -> Bool {
        return !extensions.isEmpty && Set(extensions.map{$0.lowercased()}).isSubset(of:sourceExtensions) && isSource && (current == nil || editors.contains(current!.lowercased()))
    }
}
