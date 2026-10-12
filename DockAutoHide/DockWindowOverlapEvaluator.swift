import AppKit
import CoreGraphics
import Foundation

enum DockEdge: String {
  case left
  case right
  case bottom
}

enum DockDetectionSource: String {
  case visibleFrameInset
  case dockWindowSpan
  case dockProcessWindow
  case lastKnownDisplay
  case mouseLocationFallback
}

struct DockDisplaySnapshot: Equatable {
  let displayID: CGDirectDisplayID
  let frameAppKit: CGRect
  let visibleFrameAppKit: CGRect
  let frameWindowCoordinates: CGRect
  let isMain: Bool

  func inset(for edge: DockEdge) -> CGFloat {
    switch edge {
    case .left:
      return max(0, visibleFrameAppKit.minX - frameAppKit.minX)
    case .right:
      return max(0, frameAppKit.maxX - visibleFrameAppKit.maxX)
    case .bottom:
      return max(0, visibleFrameAppKit.minY - frameAppKit.minY)
    }
  }

  var logDescription: String {
    "id=\(displayID), main=\(isMain), appKit=\(frameAppKit), window=\(frameWindowCoordinates)"
  }
}

struct DockWindowSummary {
  let ownerName: String
  let bounds: CGRect
  let displayID: CGDirectDisplayID

  var logDescription: String {
    "owner=\(ownerName), displayID=\(displayID), bounds=\(bounds)"
  }
}

struct DockOverlapDecision {
  let shouldAutoHide: Bool
  let reason: String
  let dockScreen: DockDisplaySnapshot
  let dockEdge: DockEdge
  let dockFrame: CGRect
  let detectionSource: DockDetectionSource
  let overlappingWindowSummary: DockWindowSummary?
  let fallbackReason: String?
}

final class DockWindowOverlapEvaluator {
  struct SizePreferences: Equatable {
    let tileSize: CGFloat
    let magnificationEnabled: Bool
    let largeSize: CGFloat
  }

  private struct DockSpanCandidate {
    let screen: DockDisplaySnapshot
    let rawBounds: CGRect
    let spanRange: ClosedRange<CGFloat>
    let length: CGFloat
  }

  private struct DockThicknessCacheKey: Equatable {
    let edge: DockEdge
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let sizePreferences: SizePreferences
  }

  private struct CachedDockSpan {
    let sizePreferences: SizePreferences
    let displayID: CGDirectDisplayID
    let edge: DockEdge
    let screenFrame: CGRect
    let rawBounds: CGRect
    let spanRange: ClosedRange<CGFloat>
    let length: CGFloat
  }

  private struct DockScreenSelection {
    let screen: DockDisplaySnapshot
    let detectionSource: DockDetectionSource
    let spanCandidate: DockSpanCandidate?
    let fallbackReason: String?
  }

  private struct WindowRecord {
    let ownerName: String
    let windowName: String?
    let layer: Int
    let bounds: CGRect
    let alpha: Double
    let isOnscreen: Bool
  }

  private let sizePreferencesProvider: () -> SizePreferences
  private var sizePreferences = SizePreferences(
    tileSize: 64, magnificationEnabled: false, largeSize: 64
  )
  private let windowListProvider: () -> [[String: Any]]
  private let dockDisplayHintWindowListProvider: () -> [[String: Any]]
  private let screenProvider: () -> [DockDisplaySnapshot]
  private let dockEdgeProvider: () -> DockEdge
  private let mouseLocationProvider: () -> CGPoint
  var isDockAutoHideEnabled: () -> Bool = { false }

  private var loggedMissingDockFrame: Bool = false
  private var loggedDockCandidates: Bool = false
  private var cachedVisibleDockThickness: CGFloat?
  private var cachedThicknessKey: DockThicknessCacheKey?
  private var lastKnownDockDisplayID: CGDirectDisplayID?
  private var lastKnownDockSpan: CachedDockSpan?
  private let uptimeProvider: () -> TimeInterval
  private var nextDockDisplayHintRefresh: TimeInterval = 0
  private let dockDisplayHintRefreshInterval: TimeInterval = 2

  init(
    prefsClient: DockPreferencesClient,
    windowListProvider: @escaping () -> [[String: Any]] = DockWindowOverlapEvaluator.defaultWindowList,
    dockDisplayHintWindowListProvider: @escaping () -> [[String: Any]] = DockWindowOverlapEvaluator.defaultDockDisplayHintWindowList,
    screenProvider: @escaping () -> [DockDisplaySnapshot] = DockWindowOverlapEvaluator.defaultScreenSnapshots,
    dockEdgeProvider: (() -> DockEdge)? = nil,
    mouseLocationProvider: @escaping () -> CGPoint = DockWindowOverlapEvaluator.defaultMouseLocation,
    uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sizePreferencesProvider: (() -> SizePreferences)? = nil
  ) {
    self.sizePreferencesProvider = sizePreferencesProvider ?? {
      let tileSize = CGFloat(prefsClient.readTileSize() ?? 64)
      return SizePreferences(
        tileSize: tileSize,
        magnificationEnabled: prefsClient.readMagnificationEnabled() ?? false,
        largeSize: CGFloat(prefsClient.readLargeSize() ?? Double(tileSize))
      )
    }
    self.windowListProvider = windowListProvider
    self.dockDisplayHintWindowListProvider = dockDisplayHintWindowListProvider
    self.screenProvider = screenProvider
    self.mouseLocationProvider = mouseLocationProvider
    self.uptimeProvider = uptimeProvider
    self.dockEdgeProvider = dockEdgeProvider ?? {
      switch prefsClient.readOrientation() ?? "bottom" {
      case "left":
        return .left
      case "right":
        return .right
      default:
        return .bottom
      }
    }
  }

  func evaluate() -> DockOverlapDecision? {
    sizePreferences = sizePreferencesProvider()
    let windows = windowListProvider().compactMap(parseWindowRecord)
    let edge = preferredDockEdge()
    let screens = screenProvider()

    guard let selection = preferredDockScreen(
      for: edge,
      snapshots: screens,
      windows: windows
    ) else {
      if !loggedMissingDockFrame {
        DockLogger.log("No dock screen available; skipping smart evaluation")
        loggedMissingDockFrame = true
      }
      return nil
    }
    loggedMissingDockFrame = false

    let dockScreen = selection.screen
    synchronizeThicknessCache(edge: edge, screen: dockScreen)

    let thickness = dockThickness(for: edge, on: dockScreen)
    let spanCandidate = selection.spanCandidate
    let dockFrame = dockFrame(
      edge: edge,
      screen: dockScreen,
      thickness: thickness,
      span: spanCandidate?.spanRange
    )
    let overlappingWindow = overlappingWindowSummary(
      from: windows,
      dockFrame: dockFrame,
      dockScreen: dockScreen
    )

    if !loggedDockCandidates {
      let visibleInset = dockScreen.inset(for: edge)
      let cachedThickness = cachedVisibleDockThickness ?? -1
      let overlapLog = overlappingWindow?.logDescription ?? "none"
      DockLogger.log(
        "Dock geometry: edge=\(edge.rawValue), source=\(selection.detectionSource.rawValue), fallback=\(selection.fallbackReason ?? "none"), screen={\(dockScreen.logDescription)}, visibleInset=\(visibleInset), cachedVisibleThickness=\(cachedThickness), collisionThickness=\(thickness), dockFrame=\(dockFrame), overlap=\(overlapLog), autoHide=\(isDockAutoHideEnabled())"
      )
      if let spanCandidate {
        DockLogger.log("Dock span example: \(spanCandidate.rawBounds)")
      }
      loggedDockCandidates = true
    }

    return DockOverlapDecision(
      shouldAutoHide: overlappingWindow != nil,
      reason: overlappingWindow != nil ? "windowOverlap:displayScoped" : "noOverlap:displayScoped",
      dockScreen: dockScreen,
      dockEdge: edge,
      dockFrame: dockFrame,
      detectionSource: selection.detectionSource,
      overlappingWindowSummary: overlappingWindow,
      fallbackReason: selection.fallbackReason
    )
  }

  func invalidateCaches(resetTracking: Bool = false) {
    if resetTracking {
      lastKnownDockDisplayID = nil
      lastKnownDockSpan = nil
      cachedVisibleDockThickness = nil
      cachedThicknessKey = nil
    }
    // Hiding the Dock itself changes visibleFrame. Keep the measurement until
    // the cache key detects a real display, orientation, or size change.
    loggedDockCandidates = false
    loggedMissingDockFrame = false
    nextDockDisplayHintRefresh = 0
  }

  nonisolated private static func defaultWindowList() -> [[String: Any]] {
    let options: CGWindowListOption = [
      .optionOnScreenOnly,
      .excludeDesktopElements,
    ]
    let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
    return info as? [[String: Any]] ?? []
  }

  nonisolated private static func defaultDockDisplayHintWindowList()
    -> [[String: Any]]
  {
    let options: CGWindowListOption = [
      .optionAll,
      .excludeDesktopElements,
    ]
    let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
    return info as? [[String: Any]] ?? []
  }

  nonisolated private static func defaultScreenSnapshots() -> [DockDisplaySnapshot] {
    if Thread.isMainThread {
      return makeScreenSnapshots()
    }

    var snapshots: [DockDisplaySnapshot] = []
    DispatchQueue.main.sync {
      snapshots = makeScreenSnapshots()
    }
    return snapshots
  }

  nonisolated private static func makeScreenSnapshots() -> [DockDisplaySnapshot] {
    let screens = NSScreen.screens
    guard !screens.isEmpty else {
      return []
    }

    let mainDisplayID = CGMainDisplayID()

    return screens.compactMap { screen in
      guard let displayID = displayID(for: screen) else {
        return nil
      }
      return DockDisplaySnapshot(
        displayID: displayID,
        frameAppKit: screen.frame,
        visibleFrameAppKit: screen.visibleFrame,
        frameWindowCoordinates: CGDisplayBounds(displayID),
        isMain: displayID == mainDisplayID
      )
    }
  }

  nonisolated private static func displayID(
    for screen: NSScreen
  ) -> CGDirectDisplayID? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    guard let number = screen.deviceDescription[key] as? NSNumber else {
      return nil
    }
    return CGDirectDisplayID(number.uint32Value)
  }

  nonisolated private static func defaultMouseLocation() -> CGPoint {
    if Thread.isMainThread {
      return NSEvent.mouseLocation
    }
    return DispatchQueue.main.sync {
      NSEvent.mouseLocation
    }
  }

  private func preferredDockEdge() -> DockEdge {
    dockEdgeProvider()
  }

  private func preferredDockScreen(
    for edge: DockEdge,
    snapshots: [DockDisplaySnapshot],
    windows: [WindowRecord]
  ) -> DockScreenSelection? {
    if let spanCandidate = bestDockSpanCandidate(
      from: windows,
      edge: edge,
      allScreens: snapshots
    ) {
      lastKnownDockDisplayID = spanCandidate.screen.displayID
      rememberDockSpan(spanCandidate, edge: edge)
      return DockScreenSelection(
        screen: spanCandidate.screen,
        detectionSource: .dockWindowSpan,
        spanCandidate: spanCandidate,
        fallbackReason: nil
      )
    }

    let insetCandidates =
      isDockAutoHideEnabled()
      ? []
      : snapshots
        .map({ (snapshot: $0, inset: $0.inset(for: edge)) })
        .filter({ $0.inset > 0 })
    let strongestInset = insetCandidates.map(\.inset).max()
    let strongestInsetCandidates = insetCandidates.filter {
      $0.inset == strongestInset
    }
    let insetScreen =
      strongestInsetCandidates.first(where: {
        $0.snapshot.displayID == lastKnownDockDisplayID
      })?.snapshot
      ?? strongestInsetCandidates.min(by: {
        $0.snapshot.displayID < $1.snapshot.displayID
      })?.snapshot
    if let insetScreen {
      if lastKnownDockDisplayID != insetScreen.displayID {
        lastKnownDockSpan = nil
      }
      lastKnownDockDisplayID = insetScreen.displayID
      return DockScreenSelection(
        screen: insetScreen,
        detectionSource: .visibleFrameInset,
        spanCandidate: cachedDockSpanCandidate(
          for: insetScreen,
          edge: edge
        ),
        fallbackReason: nil
      )
    }

    if let dockProcessScreen = refreshedDockDisplayHintScreen(
      from: snapshots
    ) {
      if lastKnownDockDisplayID != dockProcessScreen.displayID {
        lastKnownDockSpan = nil
      }
      lastKnownDockDisplayID = dockProcessScreen.displayID
      return DockScreenSelection(
        screen: dockProcessScreen,
        detectionSource: .dockProcessWindow,
        spanCandidate: cachedDockSpanCandidate(
          for: dockProcessScreen,
          edge: edge
        ),
        fallbackReason: "dockHidden"
      )
    }

    if let lastKnownDockDisplayID,
      let lastKnownScreen = snapshots.first(where: {
        $0.displayID == lastKnownDockDisplayID
      })
    {
      return DockScreenSelection(
        screen: lastKnownScreen,
        detectionSource: .lastKnownDisplay,
        spanCandidate: cachedDockSpanCandidate(
          for: lastKnownScreen,
          edge: edge
        ),
        fallbackReason: "dockHidden"
      )
    }

    lastKnownDockDisplayID = nil
    lastKnownDockSpan = nil

    guard let fallbackScreen = preferredScreenSnapshot(from: snapshots) else {
      return nil
    }
    return DockScreenSelection(
      screen: fallbackScreen,
      detectionSource: .mouseLocationFallback,
      spanCandidate: nil,
      fallbackReason: "dockScreenUndetermined"
    )
  }

  private func bestDockSpanCandidate(
    from windows: [WindowRecord],
    edge: DockEdge,
    allScreens: [DockDisplaySnapshot]
  ) -> DockSpanCandidate? {
    let dockWindows = windows
      .filter { $0.ownerName == "Dock" && $0.isOnscreen && $0.alpha > 0 }

    let candidates = dockWindows.compactMap { window -> DockSpanCandidate? in
      guard
        let screen = nearestScreen(
          for: window.bounds,
          screens: allScreens
        )
      else {
        return nil
      }
      guard let candidateEdge = dockEdge(for: window.bounds, screen: screen),
        candidateEdge == edge
      else {
        return nil
      }

      let clippedBounds = window.bounds.intersection(screen.frameWindowCoordinates)
      let spanRange: ClosedRange<CGFloat>
      let screenLength: CGFloat
      switch edge {
      case .bottom:
        spanRange = clippedBounds.minX...clippedBounds.maxX
        screenLength = screen.frameWindowCoordinates.width
      case .left, .right:
        spanRange = clippedBounds.minY...clippedBounds.maxY
        screenLength = screen.frameWindowCoordinates.height
      }

      let length = spanRange.upperBound - spanRange.lowerBound
      if length < 48 {
        return nil
      }
      if length >= screenLength * 0.95 {
        return nil
      }

      return DockSpanCandidate(
        screen: screen,
        rawBounds: window.bounds,
        spanRange: spanRange,
        length: length
      )
    }

    guard !candidates.isEmpty else {
      return nil
    }

    let insetCandidates =
      isDockAutoHideEnabled()
      ? []
      : candidates.filter {
        $0.screen.inset(for: edge) > 0
      }
    if let insetCandidate = preferredCandidate(from: insetCandidates) {
      return insetCandidate
    }

    let mouseLocation = mouseLocationProvider()
    if let pointerCandidate = preferredCandidate(
      from: candidates.filter {
        $0.screen.frameAppKit.contains(mouseLocation)
          && isNearDockEdge(
            mouseLocation,
            edge: edge,
            screenFrame: $0.screen.frameAppKit
          )
      }
    ) {
      return pointerCandidate
    }

    if let lastKnownDockDisplayID,
      let lastKnownCandidate = preferredCandidate(
        from: candidates.filter {
          $0.screen.displayID == lastKnownDockDisplayID
        }
      )
    {
      return lastKnownCandidate
    }

    return preferredCandidate(from: candidates)
  }

  private func preferredCandidate(
    from candidates: [DockSpanCandidate]
  ) -> DockSpanCandidate? {
    candidates.max { lhs, rhs in
      if lhs.length != rhs.length {
        return lhs.length < rhs.length
      }
      return lhs.screen.displayID > rhs.screen.displayID
    }
  }

  private func refreshedDockDisplayHintScreen(
    from screens: [DockDisplaySnapshot]
  ) -> DockDisplaySnapshot? {
    let now = uptimeProvider()
    guard now >= nextDockDisplayHintRefresh else {
      return nil
    }
    nextDockDisplayHintRefresh = now + dockDisplayHintRefreshInterval

    let candidates = dockDisplayHintWindowListProvider()
      .compactMap(parseWindowRecord)
      .filter {
        $0.ownerName == "Dock"
          && $0.windowName == "Dock"
          && $0.layer > 0
          && $0.alpha > 0
      }
      .compactMap { window -> DockDisplaySnapshot? in
        guard let screen = nearestScreen(
          for: window.bounds,
          screens: screens
        ) else {
          return nil
        }
        let screenFrame = screen.frameWindowCoordinates
        let intersection = window.bounds.intersection(screenFrame)
        guard !intersection.isNull, !intersection.isEmpty else {
          return nil
        }
        let screenArea = screenFrame.width * screenFrame.height
        let coveredArea = intersection.width * intersection.height
        let windowArea = window.bounds.width * window.bounds.height
        guard screenArea > 0, windowArea > 0,
          coveredArea / screenArea >= 0.95,
          coveredArea / windowArea >= 0.95
        else {
          return nil
        }
        return screen
      }

    // Full-screen Dock-owned windows are only a hint. Multiple displays
    // provide no reliable evidence of which one currently hosts the Dock.
    guard Set(candidates.map(\.displayID)).count == 1 else { return nil }
    return candidates.first
  }

  private func isNearDockEdge(
    _ location: CGPoint,
    edge: DockEdge,
    screenFrame: CGRect
  ) -> Bool {
    let tolerance: CGFloat = 12
    switch edge {
    case .left:
      return abs(location.x - screenFrame.minX) <= tolerance
    case .right:
      return abs(location.x - screenFrame.maxX) <= tolerance
    case .bottom:
      return abs(location.y - screenFrame.minY) <= tolerance
    }
  }

  private func rememberDockSpan(
    _ candidate: DockSpanCandidate,
    edge: DockEdge
  ) {
    lastKnownDockSpan = CachedDockSpan(
      sizePreferences: sizePreferences,
      displayID: candidate.screen.displayID,
      edge: edge,
      screenFrame: candidate.screen.frameWindowCoordinates,
      rawBounds: candidate.rawBounds,
      spanRange: candidate.spanRange,
      length: candidate.length
    )
  }

  private func cachedDockSpanCandidate(
    for screen: DockDisplaySnapshot,
    edge: DockEdge
  ) -> DockSpanCandidate? {
    guard let lastKnownDockSpan,
      lastKnownDockSpan.displayID == screen.displayID,
      lastKnownDockSpan.edge == edge,
      lastKnownDockSpan.sizePreferences == sizePreferences,
      lastKnownDockSpan.screenFrame == screen.frameWindowCoordinates
    else {
      self.lastKnownDockSpan = nil
      return nil
    }

    return DockSpanCandidate(
      screen: screen,
      rawBounds: lastKnownDockSpan.rawBounds,
      spanRange: lastKnownDockSpan.spanRange,
      length: lastKnownDockSpan.length
    )
  }

  private func overlappingWindowSummary(
    from windows: [WindowRecord],
    dockFrame: CGRect,
    dockScreen: DockDisplaySnapshot
  ) -> DockWindowSummary? {
    let ignoredOwners: Set<String> = [
      "Dock",
      "WindowServer",
      "SystemUIServer",
      "Control Center",
      "Notification Center",
      "Spotlight",
      "loginwindow",
      "ScreenSaverEngine",
    ]

    for window in windows {
      if ignoredOwners.contains(window.ownerName) {
        continue
      }
      if window.layer != 0 || !window.isOnscreen || window.alpha <= 0 {
        continue
      }

      let effectiveBounds = effectiveWindowBounds(window.bounds)
      guard effectiveBounds.intersects(dockScreen.frameWindowCoordinates) else {
        continue
      }

      if effectiveBounds.intersects(dockFrame) {
        return DockWindowSummary(
          ownerName: window.ownerName,
          bounds: window.bounds,
          displayID: dockScreen.displayID
        )
      }
    }

    return nil
  }

  private func dockFrame(
    edge: DockEdge,
    screen: DockDisplaySnapshot,
    thickness: CGFloat,
    span: ClosedRange<CGFloat>?
  ) -> CGRect {
    switch edge {
    case .left:
      return CGRect(
        x: screen.frameWindowCoordinates.minX,
        y: span?.lowerBound ?? screen.frameWindowCoordinates.minY,
        width: thickness,
        height: span.map { $0.upperBound - $0.lowerBound }
          ?? screen.frameWindowCoordinates.height
      )
    case .right:
      return CGRect(
        x: screen.frameWindowCoordinates.maxX - thickness,
        y: span?.lowerBound ?? screen.frameWindowCoordinates.minY,
        width: thickness,
        height: span.map { $0.upperBound - $0.lowerBound }
          ?? screen.frameWindowCoordinates.height
      )
    case .bottom:
      return CGRect(
        x: span?.lowerBound ?? screen.frameWindowCoordinates.minX,
        y: screen.frameWindowCoordinates.maxY - thickness,
        width: span.map { $0.upperBound - $0.lowerBound }
          ?? screen.frameWindowCoordinates.width,
        height: thickness
      )
    }
  }

  private func dockThickness(for edge: DockEdge, on screen: DockDisplaySnapshot)
    -> CGFloat
  {
    let visibleInset = screen.inset(for: edge)
    if !isDockAutoHideEnabled(),
      visibleInset > 0
    {
      cachedVisibleDockThickness = visibleInset
      return visibleInset
    }
    if let cachedVisibleDockThickness,
      cachedVisibleDockThickness > 0
    {
      return cachedVisibleDockThickness
    }
    return expectedVisibleDockThickness()
  }

  private func synchronizeThicknessCache(edge: DockEdge, screen: DockDisplaySnapshot) {
    let cacheKey = DockThicknessCacheKey(
      edge: edge,
      displayID: screen.displayID,
      screenFrame: screen.frameWindowCoordinates,
      sizePreferences: sizePreferences
    )

    if cachedThicknessKey != cacheKey {
      cachedThicknessKey = cacheKey
      cachedVisibleDockThickness = nil
      loggedDockCandidates = false
    }
  }

  private func parseWindowRecord(_ window: [String: Any]) -> WindowRecord? {
    guard let ownerName = window[kCGWindowOwnerName as String] as? String else {
      return nil
    }
    guard let bounds = windowBounds(window) else {
      return nil
    }
    let alpha = window[kCGWindowAlpha as String] as? Double ?? 1.0
    let isOnscreen = window[kCGWindowIsOnscreen as String] as? Bool ?? true
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    return WindowRecord(
      ownerName: ownerName,
      windowName: window[kCGWindowName as String] as? String,
      layer: layer,
      bounds: bounds,
      alpha: alpha,
      isOnscreen: isOnscreen
    )
  }

  private func windowBounds(_ window: [String: Any]) -> CGRect? {
    guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any]
    else {
      return nil
    }
    guard let x = cgFloat(boundsDict["X"]),
      let y = cgFloat(boundsDict["Y"]),
      let width = cgFloat(boundsDict["Width"]),
      let height = cgFloat(boundsDict["Height"])
    else {
      return nil
    }
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
      width > 0, height > 0, (x + width).isFinite, (y + height).isFinite
    else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
  }

  private func cgFloat(_ value: Any?) -> CGFloat? {
    if let number = value as? NSNumber {
      return CGFloat(truncating: number)
    }
    if let doubleValue = value as? Double {
      return CGFloat(doubleValue)
    }
    if let intValue = value as? Int {
      return CGFloat(intValue)
    }
    return nil
  }

  private func nearestScreen(
    for bounds: CGRect,
    screens: [DockDisplaySnapshot]
  ) -> DockDisplaySnapshot? {
    guard !screens.isEmpty else {
      return nil
    }

    var bestScreen = screens[0]
    var bestArea: CGFloat = 0
    for screen in screens {
      let intersection = bounds.intersection(screen.frameWindowCoordinates)
      if intersection.isNull || intersection.isEmpty {
        continue
      }
      let area = intersection.width * intersection.height
      if area > bestArea {
        bestArea = area
        bestScreen = screen
      }
    }
    return bestArea > 0 ? bestScreen : nil
  }

  private func dockEdge(
    for bounds: CGRect,
    screen: DockDisplaySnapshot
  ) -> DockEdge? {
    let frame = screen.frameWindowCoordinates
    let tolerance: CGFloat = 6
    let leftDistance = abs(bounds.minX - frame.minX)
    let rightDistance = abs(bounds.maxX - frame.maxX)
    let bottomDistance = abs(bounds.maxY - frame.maxY)

    if bounds.height > bounds.width {
      if leftDistance <= tolerance || rightDistance <= tolerance {
        return leftDistance <= rightDistance ? .left : .right
      }
    }

    if bottomDistance <= tolerance {
      return .bottom
    }
    if leftDistance <= tolerance {
      return .left
    }
    if rightDistance <= tolerance {
      return .right
    }
    return nil
  }

  private func expectedVisibleDockThickness() -> CGFloat {
    let iconSize = sizePreferences.magnificationEnabled
      ? max(sizePreferences.tileSize, sizePreferences.largeSize)
      : sizePreferences.tileSize

    return min(160.0, max(28.0, iconSize + 12.0))
  }

  private func effectiveWindowBounds(_ bounds: CGRect) -> CGRect {
    let insetX = min(6.0, max(0.0, bounds.width / 20.0))
    let insetY = min(6.0, max(0.0, bounds.height / 20.0))
    let effectiveBounds = bounds.insetBy(dx: insetX, dy: insetY)
    if effectiveBounds.isNull || effectiveBounds.isEmpty {
      return bounds
    }
    return effectiveBounds
  }

  private func preferredScreenSnapshot(from snapshots: [DockDisplaySnapshot])
    -> DockDisplaySnapshot?
  {
    guard !snapshots.isEmpty else {
      return nil
    }

    let mouseLocation = mouseLocationProvider()

    if let pointerScreen = snapshots.first(where: { snapshot in
      snapshot.frameAppKit.contains(mouseLocation)
    }) {
      return pointerScreen
    }

    return snapshots.first
  }
}
