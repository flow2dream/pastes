#!/usr/bin/env swift

// Offline release gate: inspect a local DMG without installing or launching it.
// Usage: xcrun swift scripts/validate-update.swift appcast.xml Pastes.dmg [enclosure-url]

import Foundation
import CryptoKit

struct ValidationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct FeedItem {
    var title = ""
    var minimumSystemVersion = ""
    var enclosure: [String: String] = [:]
}

final class FeedParser: NSObject, XMLParserDelegate {
    var items: [FeedItem] = []
    private var item: FeedItem?
    private var field = ""
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "item" { item = FeedItem() }
        guard item != nil else { return }
        if elementName == "enclosure" {
            item?.enclosure.merge(attributeDict) { _, newValue in newValue }
        }
        field = elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard item != nil else { return }
        if elementName == field {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if elementName == "title" { item?.title = value }
            if elementName == "sparkle:minimumSystemVersion" { item?.minimumSystemVersion = value }
            if elementName == "sparkle:version" || elementName == "sparkle:shortVersionString" {
                item?.enclosure[elementName] = value
            }
        }
        if elementName == "item", let item {
            items.append(item)
            self.item = nil
        }
    }
}

func required(_ dictionary: [String: Any], _ key: String) throws -> String {
    guard let value = dictionary[key] as? String, !value.isEmpty else {
        throw ValidationError("Missing or invalid \(key).")
    }
    return value
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ValidationError("\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(String(decoding: errorData, as: UTF8.self))")
    }
    return data
}

func main() throws {
    guard (3...4).contains(CommandLine.arguments.count) else {
        throw ValidationError("Usage: xcrun swift scripts/validate-update.swift <appcast.xml> <Pastes.dmg> [enclosure-url]")
    }
    let feedURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    guard archiveURL.pathExtension.lowercased() == "dmg" else {
        throw ValidationError("This validator expects a local DMG archive.")
    }
    let parser = XMLParser(data: try Data(contentsOf: feedURL))
    let delegate = FeedParser()
    parser.delegate = delegate
    guard parser.parse() else { throw parser.parserError ?? ValidationError("Invalid appcast XML.") }
    let selectedURL = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : nil
    guard let item = delegate.items.first(where: { selectedURL == nil || $0.enclosure["url"] == selectedURL }) else {
        throw ValidationError("No matching appcast enclosure found.")
    }
    let enclosure = item.enclosure
    let version = try required(enclosure, "sparkle:version")
    let shortVersion = try required(enclosure, "sparkle:shortVersionString")
    let downloadURL = try required(enclosure, "url")
    guard URL(string: downloadURL)?.scheme == "https" else {
        throw ValidationError("The enclosure must use HTTPS.")
    }
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    guard let length = enclosure["length"].flatMap(Int.init), archive.count == length else {
        throw ValidationError("Archive size \(archive.count) does not match enclosure length \(enclosure["length"] ?? "missing").")
    }
    guard let signatureString = enclosure["sparkle:edSignature"], let signature = Data(base64Encoded: signatureString) else {
        throw ValidationError("Missing or invalid enclosure Ed25519 signature.")
    }
    // Use the project's trusted key, rather than trusting a key supplied only
    // by the archive being validated. Key rotation needs a separate review.
    let sourceInfoURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("pastes/Info.plist")
    guard let sourceInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: sourceInfoURL), format: nil) as? [String: Any] else {
        throw ValidationError("Invalid project Info.plist.")
    }
    let trustedKeyString = try required(sourceInfo, "SUPublicEDKey")
    guard let trustedKeyData = Data(base64Encoded: trustedKeyString) else {
        throw ValidationError("Invalid project Ed25519 public key.")
    }
    let trustedKey = try Curve25519.Signing.PublicKey(rawRepresentation: trustedKeyData)
    guard trustedKey.isValidSignature(signature, for: archive) else {
        throw ValidationError("The archive's Ed25519 signature does not match the project's trusted public key.")
    }

    let mountData = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", archiveURL.path])
    guard let mountInfo = try PropertyListSerialization.propertyList(from: mountData, format: nil) as? [String: Any],
          let entities = mountInfo["system-entities"] as? [[String: Any]] else {
        throw ValidationError("Cannot read mounted DMG metadata.")
    }
    let mountPoints = entities.compactMap { $0["mount-point"] as? String }
    defer {
        for mountPoint in mountPoints.reversed() {
            do { try run("/usr/bin/hdiutil", ["detach", mountPoint]) }
            catch { fputs("Could not unmount \(mountPoint): \(error)\n", stderr) }
        }
    }
    var applications: [URL] = []
    for mountPoint in mountPoints {
        applications += try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: mountPoint), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
    }
    guard applications.count == 1, let appURL = applications.first else {
        throw ValidationError("Expected exactly one application at the DMG volume root.")
    }
    let infoData = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
        throw ValidationError("Invalid application Info.plist.")
    }
    let identifier = try required(info, "CFBundleIdentifier")
    guard identifier == "com.pastes.app.pastes", info["PASTESDevelopmentBuild"] as? Bool != true else {
        throw ValidationError("A development application must not be published to the production feed (\(identifier)).")
    }
    let actualVersion = try required(info, "CFBundleVersion")
    guard version == actualVersion else {
        throw ValidationError("sparkle:version=\(version) differs from application CFBundleVersion=\(actualVersion).")
    }
    let actualShortVersion = try required(info, "CFBundleShortVersionString")
    guard shortVersion == actualShortVersion else {
        throw ValidationError("sparkle:shortVersionString=\(shortVersion) differs from application version=\(actualShortVersion).")
    }
    guard item.title.contains(actualShortVersion) else {
        throw ValidationError("Item title does not include the application's display version \(actualShortVersion).")
    }
    let appMinimum = try required(info, "LSMinimumSystemVersion")
    guard !item.minimumSystemVersion.isEmpty,
          item.minimumSystemVersion.compare(appMinimum, options: .numeric) != .orderedAscending else {
        throw ValidationError("Feed minimum system version must be at least the application's \(appMinimum).")
    }
    let keyString = try required(info, "SUPublicEDKey")
    guard keyString == trustedKeyString else {
        throw ValidationError("Application public key differs from the project's trusted key; review key rotation before publishing.")
    }
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
    print("Validated \(appURL.lastPathComponent): build \(version), version \(shortVersion), \(archive.count) bytes; Ed25519 signature and code signature valid.")
}

do { try main() }
catch {
    fputs("Update validation failed: \(error)\n", stderr)
    exit(1)
}
