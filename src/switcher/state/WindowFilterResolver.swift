import Foundation

/// Decides whether a single window is shown to the user in the switcher, given the per-shortcut
/// filter preferences and the surrounding context. Pure kernel: takes the window's `WindowState`,
/// the app's `ApplicationState`, the dropdown booleans (defaulted to `false` so tests only spell out
/// what they exercise), the runtime context (frontmost pid, visible spaces, exceptions), and a
/// **lazy** `isOnPreferredScreen` — the one fact that's irreducibly OS-coupled (`Window.isOnScreen`
/// touches `Spaces.screenSpacesMap` + multi-screen quartz math). Everything else is a pure
/// expression over the inputs, evaluated inline so `&&` short-circuits exactly like the original.
enum WindowFilterResolver {
    /// True iff the window passes every active filter. Mirrors the original predicate term-for-term;
    /// `isOnPreferredScreen` is an `@autoclosure` so the (relatively expensive) OS call only fires
    /// when the short-circuit reaches it — phantom / hidden / windowless windows never trigger it.
    static func shouldShow(_ s: WindowState, _ app: ApplicationState,
                           onlyFrontmostApp: Bool = false,       // appsToShow == .active
                           excludeFrontmostApp: Bool = false,    // appsToShow == .nonActive
                           hideHidden: Bool = false,             // showHiddenWindows == .hide
                           hideWindowless: Bool = false,         // showWindowlessApps == .hide
                           hideFullscreen: Bool = false,         // showFullscreenWindows == .hide
                           hideMinimized: Bool = false,          // showMinimizedWindows == .hide
                           onlyVisibleSpaces: Bool = false,      // spacesToShow == .visible
                           onlyNonVisibleSpaces: Bool = false,   // spacesToShow == .nonVisible
                           onlyPreferredScreen: Bool = false,    // screensToShow == .showingAltTab
                           separateTabs: Bool = false,           // groupTabs == .separateWindows
                           frontmostPid: pid_t? = nil,
                           visibleSpaceIds: [UInt64] = [],       // CGSSpaceID === UInt64
                           exceptions: [ExceptionEntry] = [],
                           isOnPreferredScreen: @autoclosure () -> Bool) -> Bool {
        !s.isPhantom &&
            !ExceptionMatcher.hidesWindow(s, app, exceptions: exceptions,
                activeAppOverride: onlyFrontmostApp && frontmostPid == app.pid) &&
            !(onlyFrontmostApp && !(frontmostPid == app.pid)) &&
            !(excludeFrontmostApp && frontmostPid == app.pid) &&
            !(hideHidden && app.isHidden) &&
            ((!hideWindowless && s.isWindowlessApp) ||
                !s.isWindowlessApp &&
                !(hideFullscreen && s.isFullscreen) &&
                !(hideMinimized && s.isMinimized) &&
                // A held tab (kept visible through the new-tab discovery gap) just backgrounded on the
                // CURRENT visible Space, so it is Space-less yet belongs on-screen. `isPhantom` already
                // exempts it, but these Space/screen gates are SEPARATE and would still hide it — the exact
                // vanish that defeated the hold on the FIRST tab of a window, where no group exists yet to
                // borrow it a Space (live capture 2026-07-24: `(h)…sp[]` dumped with a `-` prefix). Treat
                // held as "on the visible Space and preferred screen": shows under `.visible`, hidden under
                // `.nonVisible`, and never dropped by the preferred-screen gate.
                !(onlyVisibleSpaces && !s.isHeldVisibleForTab && !inAnyVisibleSpace(s, visibleSpaceIds)) &&
                !(onlyNonVisibleSpaces && (s.isHeldVisibleForTab || inAnyVisibleSpace(s, visibleSpaceIds))) &&
                !(onlyPreferredScreen && !s.isHeldVisibleForTab && !isOnPreferredScreen()) &&
                (separateTabs || !s.isTabbed))
    }

    private static func inAnyVisibleSpace(_ s: WindowState, _ visibleSpaceIds: [UInt64]) -> Bool {
        visibleSpaceIds.contains { visibleSpace in s.spaceIds.contains { $0 == visibleSpace } }
    }
}

struct SplitViewCandidate: Equatable {
    let id: String
    let spaceIds: [UInt64]          // CGSSpaceID === UInt64
    let lastFocusOrder: Int
    let creationOrder: Int
}

/// macOS Split View puts two fullscreen windows in ONE fullscreen Space; an ordinary fullscreen Space holds
/// exactly one. So 2+ shown, untabbed, fullscreen windows sharing a single Space are a split pair, and the
/// switcher lists the pair once, as its most recently focused member.
enum SplitViewResolver {
    static func hiddenIds(_ candidates: [SplitViewCandidate]) -> Set<String> {
        let singleSpace = candidates.compactMap { c -> (UInt64, SplitViewCandidate)? in
            guard c.spaceIds.count == 1, c.spaceIds[0] != UInt64.max else { return nil }
            return (c.spaceIds[0], c)
        }
        let groups = Dictionary(grouping: singleSpace, by: { $0.0 }).values.filter { $0.count > 1 }
        return Set(groups.flatMap { group in
            let members = group.map { $0.1 }
            let keeper = members.min {
                if $0.lastFocusOrder != $1.lastFocusOrder { return $0.lastFocusOrder < $1.lastFocusOrder }
                if $0.creationOrder != $1.creationOrder { return $0.creationOrder > $1.creationOrder }
                return $0.id < $1.id
            }
            return members.map { $0.id }.filter { $0 != keeper?.id }
        })
    }
}
