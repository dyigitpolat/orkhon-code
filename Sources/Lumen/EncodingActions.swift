import AppKit
extension EditorWindowController {
    @objc func openWithEncoding(_ sender:NSMenuItem) {
        let encodings:[String.Encoding]=[.windowsCP1252,.isoLatin1,.shiftJIS,.macOSRoman]
        guard encodings.indices.contains(sender.tag) else{return}
        let encoding=encodings[sender.tag],p=NSOpenPanel();p.allowsMultipleSelection=true;p.canChooseDirectories=false
        p.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK else{return}
            p.urls.forEach { self?.openURL($0,fallbackEncoding:encoding) }
        }
    }
}
