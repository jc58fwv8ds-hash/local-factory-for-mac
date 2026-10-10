import Foundation

struct IconEntry {
    let type: String
    let fileName: String
}

let entries = [
    IconEntry(type: "icp4", fileName: "icon_16x16.png"),
    IconEntry(type: "icp5", fileName: "icon_32x32.png"),
    IconEntry(type: "ic11", fileName: "icon_16x16@2x.png"),
    IconEntry(type: "icp6", fileName: "icon_32x32@2x.png"),
    IconEntry(type: "ic12", fileName: "icon_32x32@2x.png"),
    IconEntry(type: "ic07", fileName: "icon_128x128.png"),
    IconEntry(type: "ic08", fileName: "icon_256x256.png"),
    IconEntry(type: "ic13", fileName: "icon_128x128@2x.png"),
    IconEntry(type: "ic09", fileName: "icon_512x512.png"),
    IconEntry(type: "ic14", fileName: "icon_256x256@2x.png"),
    IconEntry(type: "ic10", fileName: "icon_512x512@2x.png")
]

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: make_icns.swift <input.iconset> <output.icns>\n".utf8)
    )
    exit(64)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    let bigEndian = value.bigEndian
    return withUnsafeBytes(of: bigEndian) { Array($0) }
}

var payload = Data()
for entry in entries {
    let fileURL = iconsetURL.appendingPathComponent(entry.fileName)
    let imageData = try Data(contentsOf: fileURL)
    guard let typeData = entry.type.data(using: .ascii), typeData.count == 4 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    payload.append(typeData)
    payload.append(contentsOf: bigEndianBytes(UInt32(imageData.count + 8)))
    payload.append(imageData)
}

var output = Data("icns".utf8)
output.append(contentsOf: bigEndianBytes(UInt32(payload.count + 8)))
output.append(payload)
try output.write(to: outputURL, options: .atomic)

print("Created \(outputURL.path) with \(entries.count) image representations")
