import Foundation

/// The web pages the iOS app links to. The privacy policy is the website's `/privacy/` page; App
/// Review requires a link to it inside the app, and App Store Connect lists the same address.
enum AppLinks {
    static let privacyPolicy = URL(string: "https://aeroops.app/privacy/")!
    static let sourceCode = URL(string: "https://github.com/gusquadri/AeroOps")!
}
