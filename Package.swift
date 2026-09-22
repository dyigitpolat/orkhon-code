// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(name: "Lumen", platforms: [.macOS(.v13)], products: [.executable(name: "Lumen", targets: ["Lumen"])], targets: [
 .target(name: "LumenCore"),
 .executableTarget(name:"SSHAskpass"),
 .target(name: "SwiftTerm", path: "Vendor/SwiftTerm/Sources/SwiftTerm", exclude: ["Mac/README.md"]),
 .target(name: "EditorBridge", publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-fobjc-arc", "-I\(root)/Vendor/scintilla/include", "-I\(root)/Vendor/scintilla/cocoa", "-I\(root)/Vendor/lexilla/include"])], linkerSettings: [.unsafeFlags(["-L\(root)/work/build/native", "-lscintilla", "-llexilla", "-lc++"]), .linkedFramework("Cocoa"), .linkedFramework("QuartzCore")]),
 .executableTarget(name: "Lumen", dependencies: ["LumenCore","EditorBridge","SwiftTerm"]),
 .testTarget(name: "LumenCoreTests", dependencies: ["LumenCore"])
], cxxLanguageStandard: .cxx17)
