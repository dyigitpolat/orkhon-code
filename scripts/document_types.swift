import Foundation
@main struct DocumentTypes {
    static func main() throws {FileHandle.standardOutput.write(try JSONEncoder().encode(AssociationPolicy.catalog.keys.sorted()))}
}
