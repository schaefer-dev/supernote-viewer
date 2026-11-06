import Foundation

/// Decides when to show Apple's rating prompt (`requestReview`): once per app version, after
/// several documents were opened, and only when the reader is closed and the library comes back,
/// never while someone reads. iOS itself limits the prompt to three times a year.
struct ReviewPrompt {
    static let documentsBeforeAsking = 5
    private static let openedKey = "mobile.review.documentsOpened"
    private static let askedVersionKey = "mobile.review.askedVersion"

    let defaults: UserDefaults
    let version: String
    let enabled: Bool

    init(defaults: UserDefaults = .standard,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         enabled: Bool = ReviewPrompt.enabledInThisBuild) {
        self.defaults = defaults
        self.version = version
        self.enabled = enabled
    }

    var documentsOpened: Int { defaults.integer(forKey: Self.openedKey) }

    func documentOpened() {
        defaults.set(documentsOpened + 1, forKey: Self.openedKey)
    }

    /// True once enough documents were opened and this version has not asked yet. Asking is recorded.
    func shouldAskOnReturningToLibrary() -> Bool {
        guard enabled, documentsOpened >= Self.documentsBeforeAsking,
              defaults.string(forKey: Self.askedVersionKey) != version else { return false }
        defaults.set(version, forKey: Self.askedVersionKey)
        return true
    }

    /// Debug builds show the prompt every time, which would interrupt UI tests and screenshot runs.
    /// There it appears only with `--review-prompt` (Edit Scheme → Run → Arguments).
    #if DEBUG
    static let enabledInThisBuild = ProcessInfo.processInfo.arguments.contains("--review-prompt")
    #else
    static let enabledInThisBuild = true
    #endif
}
