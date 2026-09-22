import Foundation

enum WorkspacePaths {
    static func commonParent(of files:[URL])->URL? {
        guard let first=files.first else{return nil}
        var parts=first.standardizedFileURL.deletingLastPathComponent().pathComponents
        for file in files.dropFirst() {
            let other=file.standardizedFileURL.deletingLastPathComponent().pathComponents
            parts=Array(zip(parts,other).prefix(while:{$0==$1}).map{$0.0})
        }
        return URL(fileURLWithPath:NSString.path(withComponents:parts),isDirectory:true)
    }
}
