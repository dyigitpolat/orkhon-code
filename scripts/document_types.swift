import Foundation
@main struct DocumentTypes {
    static func main() throws {FileHandle.standardOutput.write(try JSONEncoder().encode(["types":AssociationPolicy.catalog.keys.sorted(),"extensions":AssociationPolicy.sourceExtensions.sorted()]))}
}
