import Foundation
import Testing

@testable import WiFiLogger

@Test func accessPointCSVMatchesFullAddressesAndPreservesNames() throws {
    let csv = "\u{FEFF}\"bssid\",\"ap_name\"\r\n"
        + "02:11:22:33:44:a1,\"Офис, \"\"этаж 4\"\"\"\r\n"
        + "0211-2233-44A2,Гости\r\n\r\n02:ac:ce:d0:55:87,Гости"
    let directory = try WiFiAccessPointDirectory(csv: Data(csv.utf8))

    #expect(directory.bssidCount == 3)
    #expect(directory.nameCount == 2)
    #expect(directory.name(for: "02:11:22:33:44:A1") == "Офис, \"этаж 4\"")
    #expect(directory.name(for: "0211-2233-44A2") == "Гости")
    #expect(directory.name(for: "02:ac:ce:d0:55:87") == "Гости")
    #expect(directory.name(for: "02:ac:ce:d0:55:88") == nil)
    #expect(directory.name(for: nil) == nil)
}

@Test func identicalNamesForTheSameAddressAreCountedOnce() throws {
    let csv = "bssid,ap_name\n02:11:22:33:44:a1,Офис\n0211-2233-44a1,Офис\n"
    let directory = try WiFiAccessPointDirectory(csv: Data(csv.utf8))
    #expect(directory.bssidCount == 1)
    #expect(directory.nameCount == 1)
}

@Test(arguments: [
    ("\u{0301}Гости", "\u{0301}Гости"),
    ("\"\u{0301}Гости\"", "\u{0301}Гости"),
    ("\"Офис, \"\"\u{0301}этаж\"", "Офис, \"\u{0301}этаж"),
])
func accessPointCSVInterpretsSyntaxBeforeCombiningMarks(_ field: String, _ name: String) throws {
    let csv = "bssid,ap_name\n02:11:22:33:44:a1," + field
    let directory = try WiFiAccessPointDirectory(csv: Data(csv.utf8))
    #expect(directory.name(for: "02:11:22:33:44:a1") == name)
}

@Test func accessPointReplacementCountsAddressesByTheirNameChange() throws {
    let previousCSV = """
        bssid,ap_name
        02:11:22:33:44:a1,Офис
        02:ac:ce:d0:55:82,Вход
        02:ac:ce:d0:55:83,Гости
        02:ac:ce:d0:55:84,Гости
        """
    let candidateCSV = """
        bssid,ap_name
        0211-2233-44A1,Офис
        02:11:22:33:44:a1,Офис
        02:ac:ce:d0:55:82,Склад
        02:ac:ce:d0:55:85,Гости
        """
    let previous = try WiFiAccessPointDirectory(csv: Data(previousCSV.utf8))
    let candidate = try WiFiAccessPointDirectory(csv: Data(candidateCSV.utf8))

    #expect(candidate.changes(from: previous) == .init(added: 1, removed: 2, renamed: 1))
    #expect(previous.changes(from: candidate) == .init(added: 2, removed: 1, renamed: 1))
}

@Test func accessPointReplacementDetectsNewAddressesWithEqualTotals() throws {
    let previous = try WiFiAccessPointDirectory(csv: Data("bssid,ap_name\n02:11:22:33:44:a1,Офис".utf8))
    let candidate = try WiFiAccessPointDirectory(csv: Data("bssid,ap_name\n02:ac:ce:d0:55:82,Офис".utf8))

    #expect(candidate.changes(from: previous) == .init(added: 1, removed: 1, renamed: 0))
    #expect(candidate.changes(from: candidate) == .init(added: 0, removed: 0, renamed: 0))
}

@Test(arguments: [
    ("name,bssid\nОфис,02:11:22:33:44:a1", WiFiAccessPointCSVError.header),
    ("bssid,ap_name\n", .empty),
    ("bssid,ap_name\n02:11:22:33:44:a1,  ", .invalidName(line: 2)),
    ("bssid,ap_name\n02:11:22:33:44:a1,\tОфис", .invalidName(line: 2)),
    ("bssid,ap_name\n02:11:22:33:44:a1,\"Офис\t\"", .invalidName(line: 2)),
    ("bssid,ap_name\n02:ac:ce:d0,Офис", .invalidBSSID(line: 2)),
    ("bssid,ap_name\n02:11:22:33:44:a1,Офис,лишнее", .row(line: 2)),
    ("bssid,ap_name\n02:11:22:33:44:a1,Офис,\u{0301}лишнее", .row(line: 2)),
    ("bssid,ap_name\r\n\r\n02:11:22:33:44:a1,\"Офис", .row(line: 3)),
    ("bssid,ap_name\n02:11:22:33:44:a1,Офис\n0211-2233-44A1,Гости", .conflictingName(line: 3)),
])
func accessPointCSVRejectsInvalidInput(_ csv: String, _ error: WiFiAccessPointCSVError) {
    #expect(throws: error) { try WiFiAccessPointDirectory(csv: Data(csv.utf8)) }
}

@Test func accessPointCSVRejectsInvalidUTF8() {
    #expect(throws: WiFiAccessPointCSVError.encoding) {
        try WiFiAccessPointDirectory(csv: Data([0xFF]))
    }
}

@Test func savedAccessPointDirectoryCanBeReopenedAndReplaced() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let saved = directory.appending(path: "access-points.csv")
    #expect(try WiFiAccessPointDirectory.load(from: saved) == nil)

    let first = try WiFiAccessPointDirectory(csv: Data("bssid,ap_name\n02:11:22:33:44:a1,Офис".utf8))
    try first.save(to: saved)
    #expect(try WiFiAccessPointDirectory.load(from: saved)?.name(for: "02:11:22:33:44:a1") == "Офис")

    let second = try WiFiAccessPointDirectory(csv: Data("bssid,ap_name\n02:11:22:33:44:a2,Гости".utf8))
    try second.save(to: saved)
    let loaded = try WiFiAccessPointDirectory.load(from: saved)
    let reopened = try #require(loaded)
    #expect(reopened.name(for: "02:11:22:33:44:a1") == nil)
    #expect(reopened.name(for: "02:11:22:33:44:a2") == "Гости")
}

@Test(arguments: [
    ("\tГости\t", "Гости", WiFiAccessPointCSVError.invalidName(line: 2)),
    ("Офис,\u{0301}этаж", "Офис,\u{0301}этаж", .row(line: 2)),
])
func savedLegacyAccessPointDirectoryReopensWithoutAllowingNewImports(
    _ field: String, _ name: String, _ error: WiFiAccessPointCSVError
) throws {
    let address = "02:11:22:33:44:a1"
    let csv = Data("bssid,ap_name\n\(address),\(field)".utf8)
    let saved = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: saved) }
    try csv.write(to: saved, options: .atomic)

    #expect(throws: error) { try WiFiAccessPointDirectory(csv: csv) }
    #expect(try WiFiAccessPointDirectory.load(from: saved)?.name(for: address) == name)
    #expect(try Data(contentsOf: saved) == csv)
}

@Test func unreadableAccessPointDirectoryReportsTheStrictError() throws {
    let csv = Data("bssid,ap_name\n02:11:22:33:44:a1,Офис,\u{0301}\tэтаж".utf8)
    let saved = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: saved) }
    try csv.write(to: saved, options: .atomic)

    #expect(throws: WiFiAccessPointCSVError.row(line: 2)) {
        try WiFiAccessPointDirectory.load(from: saved)
    }
}
