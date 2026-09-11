import XCTest
@testable import MaterialOrganizer
import OrganizerCore

final class SettingsCompatibilityTests: XCTestCase {
    func testOldSettingsDecodeWithOverlayOff() throws {
        let original = SavedSettings(sources: ["/tmp/source"], destination: "/tmp/destination")
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["folderOverlayEnabled"])
        let restored = try JSONDecoder().decode(SavedSettings.self, from: data)
        XCTAssertFalse(restored.folderOverlayEnabled ?? false)
        XCTAssertEqual(restored.folderDockLayout ?? .init(), FolderDockLayout())
        XCTAssertEqual(restored.sources, original.sources)
        XCTAssertEqual(restored.rules, original.rules)
        XCTAssertNil(restored.folderSuggestionRules)
    }
    func testOverlayPreferenceRoundTripsWithoutChangingRulesOrConnections() throws {
        var saved = SavedSettings(sources: ["/tmp/source"], destination: "/tmp/destination", bookmarks: ["/tmp/source": Data([1, 2])])
        saved.folderOverlayEnabled = true
        saved.folderDockLayout = .init(horizontal: 0.27, vertical: 0.41, width: 648, height: 224)
        let restored = try JSONDecoder().decode(SavedSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.folderOverlayEnabled, true)
        XCTAssertEqual(restored.folderDockLayout, saved.folderDockLayout)
        XCTAssertEqual(restored.bookmarks, saved.bookmarks)
        XCTAssertEqual(restored.rules, saved.rules)
    }
    func testExplicitSuggestionRuleSurvivesSettingsReload() throws {
        var saved = SavedSettings(sources: [], destination: "/tmp/old-destination")
        saved.folderSuggestionRules = [.init(prefix: "Research", folderPath: "/tmp/research")]
        let restored = try JSONDecoder().decode(SavedSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.folderSuggestionRules, saved.folderSuggestionRules)
        XCTAssertEqual(restored.destination, saved.destination)
        XCTAssertTrue(restored.sources.isEmpty)
    }
}
