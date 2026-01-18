import Foundation
import AppKit

/// Represents a search result that can be either an app or a specific window
struct SearchResult: Identifiable, Hashable {
    let id: String
    let app: ApplicationModel
    let targetWindowIndex: Int?  // nil means target the app itself, otherwise target specific window
    let matchedText: String      // What was matched (app name, window title, etc.)
    let score: Int

    var displayName: String {
        if let windowIndex = targetWindowIndex,
           app.windows.indices.contains(windowIndex) {
            return app.windows[windowIndex].title
        }
        return app.name
    }

    var displaySubtitle: String? {
        if targetWindowIndex != nil {
            return app.name  // Show app name as subtitle when matching a window
        }
        return app.windows.first?.title  // Show first window title as subtitle when matching app
    }

    var icon: NSImage {
        app.icon
    }

    var targetWindow: WindowModel? {
        guard let index = targetWindowIndex,
              app.windows.indices.contains(index) else {
            return nil
        }
        return app.windows[index]
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

enum FuzzyMatcher {

    struct Match {
        let item: ApplicationModel
        let score: Int
        let matchedRanges: [Range<String.Index>]
    }

    /// Search and return results that can point to specific windows
    /// Uses combined "{appname} - {window title/metadata}" for matching
    static func search(_ applications: [ApplicationModel], query: String) -> [SearchResult] {
        guard !query.isEmpty else {
            // Return all apps as results when no query
            return applications.enumerated().map { index, app in
                SearchResult(
                    id: "app-\(app.pid)",
                    app: app,
                    targetWindowIndex: nil,
                    matchedText: app.name,
                    score: 1000 - index  // Preserve original order
                )
            }
        }

        let lowercaseQuery = query.lowercased()
        var results: [SearchResult] = []

        for app in applications {
            let appNameLower = app.name.lowercased()
            var appScore: Int? = nil

            // Check if app name matches
            if let (score, _) = fuzzyMatch(appNameLower, pattern: lowercaseQuery) {
                appScore = score + 200  // High priority for app name matches

                // Add the app itself as a result
                results.append(SearchResult(
                    id: "app-\(app.pid)",
                    app: app,
                    targetWindowIndex: nil,
                    matchedText: app.name,
                    score: appScore!
                ))

                // When app matches and has MULTIPLE windows, also add windows as separate results
                // Skip if app only has one window (would be redundant with app result)
                if app.windows.count > 1 {
                    for (windowIndex, window) in app.windows.enumerated() {
                        // Windows get slightly lower score than the app itself
                        let windowScore = appScore! - 10 - windowIndex
                        results.append(SearchResult(
                            id: "window-\(app.pid)-\(window.windowID)",
                            app: app,
                            targetWindowIndex: windowIndex,
                            matchedText: "\(app.name) - \(window.title)",
                            score: windowScore
                        ))
                    }
                }
            }

            // Also try matching against combined "appname - windowtitle" strings
            // This handles queries like "safari facebook" or "chrome gmail"
            // Only show individual windows if app has multiple windows (avoids duplicates)
            if app.windows.count > 1 {
                for (windowIndex, window) in app.windows.enumerated() {
                    let combinedText = "\(appNameLower) - \(window.title.lowercased())"
                    let windowTitleOnly = window.title.lowercased()

                    // Try matching the combined string
                    if let (score, _) = fuzzyMatch(combinedText, pattern: lowercaseQuery) {
                        let finalScore = score + 150

                        // Only add if we haven't already added this window (from app match above)
                        let windowId = "window-\(app.pid)-\(window.windowID)"
                        if !results.contains(where: { $0.id == windowId }) {
                            results.append(SearchResult(
                                id: windowId,
                                app: app,
                                targetWindowIndex: windowIndex,
                                matchedText: window.title,
                                score: finalScore
                            ))
                        }
                    }
                    // Also try matching window title alone
                    else if let (score, _) = fuzzyMatch(windowTitleOnly, pattern: lowercaseQuery) {
                        let finalScore = score + 140

                        let windowId = "window-\(app.pid)-\(window.windowID)"
                        if !results.contains(where: { $0.id == windowId }) {
                            results.append(SearchResult(
                                id: windowId,
                                app: app,
                                targetWindowIndex: windowIndex,
                                matchedText: window.title,
                                score: finalScore
                            ))
                        }
                    }
                }
            }

            // Score browser tabs with combined matching
            if let tabs = app.browserTabs {
                for tab in tabs {
                    let combinedTabText = "\(appNameLower) - \(tab.title.lowercased())"

                    if let (score, _) = fuzzyMatch(combinedTabText, pattern: lowercaseQuery) {
                        let finalScore = score + 100
                        results.append(SearchResult(
                            id: "tab-\(app.pid)-\(tab.id)",
                            app: app,
                            targetWindowIndex: nil,
                            matchedText: tab.title,
                            score: finalScore
                        ))
                    } else if let (score, _) = fuzzyMatch(tab.title.lowercased(), pattern: lowercaseQuery) {
                        let finalScore = score + 90
                        results.append(SearchResult(
                            id: "tab-\(app.pid)-\(tab.id)",
                            app: app,
                            targetWindowIndex: nil,
                            matchedText: tab.title,
                            score: finalScore
                        ))
                    }

                    if let url = tab.url {
                        let combinedUrlText = "\(appNameLower) - \(url.lowercased())"
                        if let (score, _) = fuzzyMatch(combinedUrlText, pattern: lowercaseQuery) {
                            let finalScore = score + 75
                            let urlId = "url-\(app.pid)-\(tab.id)"
                            if !results.contains(where: { $0.id == urlId }) {
                                results.append(SearchResult(
                                    id: urlId,
                                    app: app,
                                    targetWindowIndex: nil,
                                    matchedText: url,
                                    score: finalScore
                                ))
                            }
                        } else if let (score, _) = fuzzyMatch(url.lowercased(), pattern: lowercaseQuery) {
                            let finalScore = score + 65
                            let urlId = "url-\(app.pid)-\(tab.id)"
                            if !results.contains(where: { $0.id == urlId }) {
                                results.append(SearchResult(
                                    id: urlId,
                                    app: app,
                                    targetWindowIndex: nil,
                                    matchedText: url,
                                    score: finalScore
                                ))
                            }
                        }
                    }
                }
            }

            // Score IDE project name
            if let project = app.ideProject {
                let combinedProjectText = "\(appNameLower) - \(project.lowercased())"
                if let (score, _) = fuzzyMatch(combinedProjectText, pattern: lowercaseQuery) {
                    let finalScore = score + 125
                    results.append(SearchResult(
                        id: "project-\(app.pid)",
                        app: app,
                        targetWindowIndex: nil,
                        matchedText: project,
                        score: finalScore
                    ))
                } else if let (score, _) = fuzzyMatch(project.lowercased(), pattern: lowercaseQuery) {
                    let finalScore = score + 115
                    results.append(SearchResult(
                        id: "project-\(app.pid)",
                        app: app,
                        targetWindowIndex: nil,
                        matchedText: project,
                        score: finalScore
                    ))
                }
            }

            // Score bundle identifier (low priority, only if nothing else matched for this app)
            if appScore == nil && !results.contains(where: { $0.app.pid == app.pid }) {
                if let (score, _) = fuzzyMatch(app.bundleIdentifier.lowercased(), pattern: lowercaseQuery) {
                    results.append(SearchResult(
                        id: "bundle-\(app.pid)",
                        app: app,
                        targetWindowIndex: nil,
                        matchedText: app.bundleIdentifier,
                        score: score
                    ))
                }
            }
        }

        // Sort by score descending
        return results.sorted { $0.score > $1.score }
    }

    /// Legacy filter function for compatibility - returns applications only
    static func filter(_ applications: [ApplicationModel], query: String) -> [ApplicationModel] {
        guard !query.isEmpty else { return applications }

        let results = search(applications, query: query)

        // Deduplicate by app, keeping highest scoring match
        var seen = Set<pid_t>()
        return results.compactMap { result -> ApplicationModel? in
            guard !seen.contains(result.app.pid) else { return nil }
            seen.insert(result.app.pid)
            return result.app
        }
    }

    private static func fuzzyMatch(_ text: String, pattern: String) -> (score: Int, ranges: [Range<String.Index>])? {
        guard !pattern.isEmpty else { return (0, []) }

        var textIndex = text.startIndex
        var patternIndex = pattern.startIndex
        var matchedRanges: [Range<String.Index>] = []
        var score = 0
        var consecutiveBonus = 0
        var lastMatchIndex: String.Index?

        while textIndex < text.endIndex && patternIndex < pattern.endIndex {
            let textChar = text[textIndex]
            let patternChar = pattern[patternIndex]

            if textChar == patternChar {
                let rangeStart = textIndex
                textIndex = text.index(after: textIndex)
                patternIndex = pattern.index(after: patternIndex)
                matchedRanges.append(rangeStart..<textIndex)

                // Base score for match
                score += 10

                // Consecutive match bonus
                if let lastMatch = lastMatchIndex,
                   text.index(after: lastMatch) == rangeStart {
                    consecutiveBonus += 5
                    score += consecutiveBonus
                } else {
                    consecutiveBonus = 0
                }

                // Word boundary bonus
                if rangeStart == text.startIndex {
                    score += 25  // Match at start of string
                } else {
                    let prevIndex = text.index(before: rangeStart)
                    let prevChar = text[prevIndex]
                    if prevChar == " " || prevChar == "-" || prevChar == "_" || prevChar == "." {
                        score += 15  // Match at word boundary
                    } else if prevChar.isLowercase && textChar.isUppercase {
                        score += 15  // CamelCase boundary
                    }
                }

                lastMatchIndex = rangeStart
            } else {
                textIndex = text.index(after: textIndex)
                consecutiveBonus = 0
            }
        }

        // All pattern characters must be found
        guard patternIndex == pattern.endIndex else {
            return nil
        }

        // Bonus for shorter strings (more relevant matches)
        let lengthBonus = max(0, 50 - text.count)
        score += lengthBonus

        return (score, matchedRanges)
    }
}
