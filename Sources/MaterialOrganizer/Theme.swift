import AppKit
import CoreText
import SwiftUI

enum Theme {
    static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "MaterialOrganizer_MaterialOrganizer", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    static let blue = Color(red: 76/255, green: 146/255, blue: 233/255)
    static let soft = Color(white: 0.95)
    static let gray = Color(red: 0.4, green: 0.4, blue: 0.4)
    static func registerFonts() {
        for ext in ["otf", "ttf"] {
            for url in resources.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
    static func body(_ size: CGFloat = 14) -> Font {
        Font(nativeBody(size))
    }
    static func nativeBody(_ size: CGFloat = 14) -> NSFont {
        let fallback = NSFontDescriptor(name: "Pretendard-Regular", size: size)
        let descriptor = NSFontDescriptor(name: "Manrope-Regular", size: size).addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }
    static func display(_ size: CGFloat = 32) -> Font {
        let fallback = NSFontDescriptor(name: "Pretendard-ExtraBold", size: size)
        let descriptor = NSFontDescriptor(name: "ArchivoBlack-Regular", size: size).addingAttributes([.cascadeList: [fallback]])
        return Font(NSFont(descriptor: descriptor, size: size) ?? NSFont.boldSystemFont(ofSize: size))
    }
}
struct PillStyle: ButtonStyle {
    var filled = true
    var gridHeight: CGFloat? = nil
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.body(13)).tracking(0.13)
            .lineLimit(1).padding(.horizontal, 13).padding(.vertical, gridHeight == nil ? 9 : 0)
            .frame(maxWidth: gridHeight == nil ? nil : .infinity)
            .frame(height: gridHeight)
            .foregroundStyle(filled ? Color.white : Color.black)
            .background(filled ? Color.black : (gridHeight == nil ? Color.white : Theme.soft), in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
struct Hairline: View { var body: some View { Rectangle().fill(Color.black.opacity(0.16)).frame(height: 1) } }
struct PathText: View {
    var path: String
    var body: some View { Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "~/")).font(Theme.body(11)).foregroundStyle(Theme.gray).lineLimit(2).truncationMode(.middle).help(path).textSelection(.enabled) }
}
