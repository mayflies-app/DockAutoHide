import CoreGraphics
import Foundation

private func window(
  owner: String,
  name: String? = nil,
  bounds: CGRect,
  layer: Int = 0,
  alpha: Double = 1,
  isOnscreen: Bool = true
) -> [String: Any] {
  var record: [String: Any] = [
    kCGWindowOwnerName as String: owner,
    kCGWindowLayer as String: layer,
    kCGWindowIsOnscreen as String: isOnscreen,
    kCGWindowAlpha as String: alpha,
    kCGWindowBounds as String: [
      "X": bounds.minX,
      "Y": bounds.minY,
      "Width": bounds.width,
      "Height": bounds.height,
    ],
  ]
  if let name {
    record[kCGWindowName as String] = name
  }
  return record
}

private func display(
  id: CGDirectDisplayID,
  appKitFrame: CGRect,
  windowFrame: CGRect,
  visibleFrame: CGRect? = nil,
  isMain: Bool = false
) -> DockDisplaySnapshot {
  DockDisplaySnapshot(
    displayID: id,
    frameAppKit: appKitFrame,
    visibleFrameAppKit: visibleFrame ?? appKitFrame,
    frameWindowCoordinates: windowFrame,
    isMain: isMain
  )
}

@main
@MainActor
private enum MultiDisplayOverlapRegression {
  static func main() {
    DockLogger.isEnabled = ProcessInfo.processInfo.environment["VERBOSE"] == "1"
    testIssue11StateStabilityAndCachedSpan()
    testMultipleDockCandidatesRemainStableAndCanMigrate()
    testVisibleFrameSelectsTheDockDisplay()
    testSideDockOrientations()
    testVerticallyArrangedDisplayCoordinates()
    testMixedResolutionDisplayCoordinates()
    testWindowSpanningTwoDisplays()
    testDisplayRemovalDropsStaleGeometry()
    testGeometryAndOrientationChangesDropCachedSpan()
    testAutoHideIgnoresUnrelatedVisibleFrameInsets()
    testInvisibleAndSystemWindowsAreIgnored()
    testInitialHiddenDockUsesPointerDisplay()
    testHiddenDockProcessWindowOverridesPointerFallback()
    testVisibleInsetOverridesProcessHint()
    testAmbiguousProcessHintsUseFallback()
    testDockSpanIsClippedToDisplay()
    testMalformedWindowBoundsAreIgnored()
    testEngineLifecycle()
    testScreenRefreshPreservesMeasuredThickness()
    testOversizedDockHintIsRejected()
    testSizeChangesInvalidateHiddenGeometry()
    print("multi-display overlap regressions passed")
  }

  private static func testIssue11StateStabilityAndCachedSpan() {
    let left = display(
      id: 1,
      appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      windowFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      isMain: true
    )
    let right = display(
      id: 2,
      appKitFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
      windowFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    )

    var windows = [
      window(
        owner: "Dock",
        bounds: CGRect(x: 2500, y: 1030, width: 760, height: 50)
      ),
      window(
        owner: "RightApp",
        bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
      ),
      window(
        owner: "LeftApp",
        bounds: CGRect(x: 0, y: 0, width: 900, height: 900)
      ),
    ]

    let evaluator = makeEvaluator(
      windows: { windows },
      screens: { [left, right] },
      edge: .bottom,
      mouse: { CGPoint(x: 3000, y: 500) }
    )

    let visibleDockDecision = requireDecision(
      evaluator.evaluate(),
      context: "visible Dock on right display"
    )
    expect(visibleDockDecision.shouldAutoHide, "right overlap must hide Dock")
    expect(
      visibleDockDecision.dockScreen.displayID == right.displayID,
      "visible Dock must resolve to right display"
    )
    expect(
      visibleDockDecision.detectionSource == .dockWindowSpan,
      "visible Dock must use its window span"
    )

    windows.removeAll { owner(of: $0) == "Dock" }

    for _ in 0..<5 {
      let hiddenDockDecision = requireDecision(
        evaluator.evaluate(),
        context: "hidden Dock on right display"
      )
      expect(hiddenDockDecision.shouldAutoHide, "hidden Dock state must not flap")
      expect(
        hiddenDockDecision.dockScreen.displayID == right.displayID,
        "hidden Dock must stay on last reliable display"
      )
      expect(
        hiddenDockDecision.detectionSource == .lastKnownDisplay,
        "hidden Dock must use last reliable display"
      )
      expect(
        hiddenDockDecision.dockFrame.width == 760,
        "hidden Dock must retain its last reliable span"
      )
    }

    windows.removeAll { owner(of: $0) == "RightApp" }
    windows.append(
      window(
        owner: "BottomCornerApp",
        bounds: CGRect(x: 1920, y: 0, width: 300, height: 1080)
      )
    )

    let outsideDockSpanDecision = requireDecision(
      evaluator.evaluate(),
      context: "window outside the hidden Dock span"
    )
    expect(
      !outsideDockSpanDecision.shouldAutoHide,
      "window outside cached Dock span must not hide Dock"
    )

    windows.removeAll { owner(of: $0) == "BottomCornerApp" }
    windows.append(
      window(
        owner: "Dock",
        bounds: CGRect(x: 580, y: 1030, width: 760, height: 50)
      )
    )

    let movedDockDecision = requireDecision(
      evaluator.evaluate(),
      context: "Dock moved to left display"
    )
    expect(!movedDockDecision.shouldAutoHide, "clear left display must show Dock")
    expect(
      movedDockDecision.dockScreen.displayID == left.displayID,
      "real Dock migration must replace cached display"
    )
  }

  private static func testMultipleDockCandidatesRemainStableAndCanMigrate() {
    let left = display(
      id: 10,
      appKitFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
      windowFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
      isMain: true
    )
    let right = display(
      id: 20,
      appKitFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
      windowFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000)
    )
    var mouse = CGPoint(x: 2400, y: 0)
    let windows = [
      window(
        owner: "Dock",
        bounds: CGRect(x: 300, y: 950, width: 900, height: 50)
      ),
      window(
        owner: "Dock",
        bounds: CGRect(x: 2100, y: 950, width: 600, height: 50)
      ),
    ]
    let evaluator = makeEvaluator(
      windows: { windows },
      screens: { [left, right] },
      edge: .bottom,
      mouse: { mouse }
    )

    let pointerSelected = requireDecision(
      evaluator.evaluate(),
      context: "multiple Dock candidates near right edge"
    )
    expect(
      pointerSelected.dockScreen.displayID == right.displayID,
      "pointer at Dock edge must disambiguate multiple candidates"
    )

    mouse = CGPoint(x: 800, y: 500)
    let stableSelection = requireDecision(
      evaluator.evaluate(),
      context: "multiple Dock candidates away from edges"
    )
    expect(
      stableSelection.dockScreen.displayID == right.displayID,
      "last reliable candidate must prevent display flapping"
    )

    mouse = CGPoint(x: 800, y: 0)
    let migratedSelection = requireDecision(
      evaluator.evaluate(),
      context: "multiple Dock candidates near left edge"
    )
    expect(
      migratedSelection.dockScreen.displayID == left.displayID,
      "pointer at another Dock edge must allow real migration"
    )
  }

  private static func testVisibleFrameSelectsTheDockDisplay() {
    let left = display(
      id: 30,
      appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      windowFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      isMain: true
    )
    let rightFrame = CGRect(x: 1440, y: 0, width: 1440, height: 900)
    let right = display(
      id: 40,
      appKitFrame: rightFrame,
      windowFrame: rightFrame,
      visibleFrame: CGRect(x: 1440, y: 55, width: 1440, height: 845)
    )
    let evaluator = makeEvaluator(
      windows: {
        [
          window(owner: "RightApp", bounds: rightFrame),
        ]
      },
      screens: { [left, right] },
      edge: .bottom,
      mouse: { CGPoint(x: 700, y: 500) },
      autoHide: false
    )

    let decision = requireDecision(
      evaluator.evaluate(),
      context: "visibleFrame Dock evidence"
    )
    expect(
      decision.dockScreen.displayID == right.displayID,
      "visibleFrame inset must select right display"
    )
    expect(
      decision.detectionSource == .visibleFrameInset,
      "missing Dock window must fall back to visibleFrame"
    )
    expect(decision.dockFrame.height == 55, "visible Dock thickness must be exact")
  }

  private static func testSideDockOrientations() {
    let screen = display(
      id: 50,
      appKitFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
      windowFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
      isMain: true
    )

    let cases: [(DockEdge, CGRect, CGRect)] = [
      (
        .left,
        CGRect(x: 0, y: 180, width: 50, height: 540),
        CGRect(x: 0, y: 200, width: 500, height: 500)
      ),
      (
        .right,
        CGRect(x: 1150, y: 180, width: 50, height: 540),
        CGRect(x: 700, y: 200, width: 500, height: 500)
      ),
    ]

    for (edge, dockBounds, appBounds) in cases {
      let evaluator = makeEvaluator(
        windows: {
          [
            window(owner: "Dock", bounds: dockBounds),
            window(owner: "SideApp", bounds: appBounds),
          ]
        },
        screens: { [screen] },
        edge: edge,
        mouse: { CGPoint(x: 600, y: 450) }
      )
      let decision = requireDecision(
        evaluator.evaluate(),
        context: "\(edge.rawValue) Dock overlap"
      )
      expect(decision.shouldAutoHide, "\(edge.rawValue) Dock overlap must hide")
      expect(decision.dockEdge == edge, "decision must retain Dock orientation")
    }
  }

  private static func testVerticallyArrangedDisplayCoordinates() {
    let main = display(
      id: 60,
      appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      windowFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      isMain: true
    )
    let above = display(
      id: 70,
      appKitFrame: CGRect(x: 0, y: 1080, width: 1920, height: 1200),
      windowFrame: CGRect(x: 0, y: -1200, width: 1920, height: 1200)
    )
    let evaluator = makeEvaluator(
      windows: {
        [
          window(
            owner: "Dock",
            bounds: CGRect(x: 500, y: -50, width: 900, height: 50)
          ),
          window(
            owner: "AboveApp",
            bounds: CGRect(x: 0, y: -1200, width: 1920, height: 1200)
          ),
        ]
      },
      screens: { [main, above] },
      edge: .bottom,
      mouse: { CGPoint(x: 900, y: 1080) }
    )

    let decision = requireDecision(
      evaluator.evaluate(),
      context: "display above main display"
    )
    expect(decision.shouldAutoHide, "negative Quartz coordinates must overlap")
    expect(
      decision.dockScreen.displayID == above.displayID,
      "Dock must resolve to display above main"
    )
  }

  private static func testMixedResolutionDisplayCoordinates() {
    let main = display(
      id: 80,
      appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
      windowFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
      isMain: true
    )
    let right = display(
      id: 90,
      appKitFrame: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
      windowFrame: CGRect(x: 2560, y: 360, width: 1920, height: 1080)
    )
    let evaluator = makeEvaluator(
      windows: {
        [
          window(
            owner: "Dock",
            bounds: CGRect(x: 3100, y: 1390, width: 840, height: 50)
          ),
          window(
            owner: "ScaledApp",
            bounds: CGRect(x: 2560, y: 360, width: 1920, height: 1080)
          ),
        ]
      },
      screens: { [main, right] },
      edge: .bottom,
      mouse: { CGPoint(x: 3400, y: 0) }
    )

    let decision = requireDecision(
      evaluator.evaluate(),
      context: "mixed-resolution right display"
    )
    expect(decision.shouldAutoHide, "mixed-resolution overlap must be detected")
    expect(
      decision.dockScreen.displayID == right.displayID,
      "mixed-resolution Dock must resolve to right display"
    )
  }

  private static func testWindowSpanningTwoDisplays() {
    let left = display(
      id: 100,
      appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      windowFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      isMain: true
    )
    let right = display(
      id: 110,
      appKitFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
      windowFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    )
    let evaluator = makeEvaluator(
      windows: {
        [
          window(
            owner: "Dock",
            bounds: CGRect(x: 1920, y: 1030, width: 500, height: 50)
          ),
          window(
            owner: "SpanningApp",
            bounds: CGRect(x: 1650, y: 0, width: 400, height: 1080)
          ),
        ]
      },
      screens: { [left, right] },
      edge: .bottom,
      mouse: { CGPoint(x: 2200, y: 500) }
    )

    let decision = requireDecision(
      evaluator.evaluate(),
      context: "window spanning two displays"
    )
    expect(
      decision.shouldAutoHide,
      "window crossing into Dock display must count as overlap"
    )
  }

  private static func testDisplayRemovalDropsStaleGeometry() {
    let left = display(
      id: 120,
      appKitFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
      windowFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
      isMain: true
    )
    let right = display(
      id: 130,
      appKitFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
      windowFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000)
    )
    var screens = [left, right]
    var windows = [
      window(
        owner: "Dock",
        bounds: CGRect(x: 2050, y: 950, width: 700, height: 50)
      ),
    ]
    let evaluator = makeEvaluator(
      windows: { windows },
      screens: { screens },
      edge: .bottom,
      mouse: { CGPoint(x: 800, y: 500) }
    )

    let initial = requireDecision(
      evaluator.evaluate(),
      context: "Dock before display removal"
    )
    expect(initial.dockScreen.displayID == right.displayID, "setup must use right")

    screens = [left]
    windows = []
    evaluator.invalidateCaches()

    let afterRemoval = requireDecision(
      evaluator.evaluate(),
      context: "right display removed"
    )
    expect(
      afterRemoval.dockScreen.displayID == left.displayID,
      "removed display must not remain cached"
    )
    expect(
      afterRemoval.detectionSource == .mouseLocationFallback,
      "display removal without Dock evidence must use pointer fallback"
    )
    expect(
      afterRemoval.dockFrame.width == left.frameWindowCoordinates.width,
      "stale Dock span must be discarded after display removal"
    )
  }

  private static func testGeometryAndOrientationChangesDropCachedSpan() {
    var edge = DockEdge.bottom
    var screen = display(
      id: 135,
      appKitFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
      windowFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
      isMain: true
    )
    var windows = [
      window(
        owner: "Dock",
        bounds: CGRect(x: 450, y: 950, width: 700, height: 50)
      ),
    ]
    let evaluator = DockWindowOverlapEvaluator(
      prefsClient: DockPreferencesClient(),
      windowListProvider: { windows },
      screenProvider: { [screen] },
      dockEdgeProvider: { edge },
      mouseLocationProvider: { CGPoint(x: 800, y: 500) }
    )
    evaluator.isDockAutoHideEnabled = { true }

    let initial = requireDecision(
      evaluator.evaluate(),
      context: "cached span before geometry change"
    )
    expect(initial.dockFrame.width == 700, "setup must cache Dock span")

    windows = []
    screen = display(
      id: 135,
      appKitFrame: CGRect(x: 0, y: 0, width: 1800, height: 1000),
      windowFrame: CGRect(x: 0, y: 0, width: 1800, height: 1000),
      isMain: true
    )
    evaluator.invalidateCaches()

    let resized = requireDecision(
      evaluator.evaluate(),
      context: "same display after resolution change"
    )
    expect(
      resized.dockFrame.width == 1800,
      "resolution change must discard stale Dock span"
    )

    edge = .left
    let reoriented = requireDecision(
      evaluator.evaluate(),
      context: "Dock orientation changed"
    )
    expect(
      reoriented.dockFrame.height == 1000,
      "orientation change must not reuse bottom Dock span"
    )
  }

  private static func testAutoHideIgnoresUnrelatedVisibleFrameInsets() {
    let leftFrame = CGRect(x: 0, y: 0, width: 1500, height: 1000)
    var left = display(
      id: 136,
      appKitFrame: leftFrame,
      windowFrame: leftFrame,
      isMain: true
    )
    let right = display(
      id: 137,
      appKitFrame: CGRect(x: 1500, y: 0, width: 1500, height: 1000),
      windowFrame: CGRect(x: 1500, y: 0, width: 1500, height: 1000)
    )
    var windows = [
      window(
        owner: "Dock",
        bounds: CGRect(x: 1950, y: 950, width: 600, height: 50)
      ),
    ]
    let evaluator = makeEvaluator(
      windows: { windows },
      screens: { [left, right] },
      edge: .bottom,
      mouse: { CGPoint(x: 700, y: 500) },
      autoHide: true
    )

    let initial = requireDecision(
      evaluator.evaluate(),
      context: "right Dock before unrelated inset"
    )
    expect(initial.dockScreen.displayID == right.displayID, "setup must use right")

    windows = []
    left = display(
      id: 136,
      appKitFrame: leftFrame,
      windowFrame: leftFrame,
      visibleFrame: CGRect(x: 0, y: 80, width: 1500, height: 920),
      isMain: true
    )

    let hidden = requireDecision(
      evaluator.evaluate(),
      context: "auto-hidden Dock with unrelated visibleFrame inset"
    )
    expect(
      hidden.dockScreen.displayID == right.displayID,
      "auto-hide mode must not treat unrelated visibleFrame inset as Dock"
    )
    expect(
      hidden.detectionSource == .lastKnownDisplay,
      "auto-hide mode must retain reliable Dock display"
    )
  }

  private static func testInvisibleAndSystemWindowsAreIgnored() {
    let screen = display(
      id: 138,
      appKitFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
      windowFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
      isMain: true
    )
    let evaluator = makeEvaluator(
      windows: {
        [
          window(
            owner: "Dock",
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 900),
            layer: 20
          ),
          window(
            owner: "Dock",
            bounds: CGRect(x: 300, y: 850, width: 600, height: 50)
          ),
          window(
            owner: "TransparentApp",
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 900),
            alpha: 0
          ),
          window(
            owner: "OffscreenApp",
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 900),
            isOnscreen: false
          ),
          window(
            owner: "OverlayApp",
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 900),
            layer: 1
          ),
          window(
            owner: "WindowServer",
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 900)
          ),
        ]
      },
      screens: { [screen] },
      edge: .bottom,
      mouse: { CGPoint(x: 600, y: 400) }
    )

    let decision = requireDecision(
      evaluator.evaluate(),
      context: "non-user windows at Dock edge"
    )
    expect(
      !decision.shouldAutoHide,
      "transparent, offscreen, overlay and system windows must be ignored"
    )
  }

  private static func testInitialHiddenDockUsesPointerDisplay() {
    let left = display(
      id: 140,
      appKitFrame: CGRect(x: 0, y: 0, width: 1400, height: 900),
      windowFrame: CGRect(x: 0, y: 0, width: 1400, height: 900),
      isMain: true
    )
    let right = display(
      id: 150,
      appKitFrame: CGRect(x: 1400, y: 0, width: 1400, height: 900),
      windowFrame: CGRect(x: 1400, y: 0, width: 1400, height: 900)
    )
    let evaluator = makeEvaluator(
      windows: { [] },
      screens: { [left, right] },
      edge: .bottom,
      mouse: { CGPoint(x: 2100, y: 450) }
    )

    let decision = requireDecision(
      evaluator.evaluate(),
      context: "initial hidden Dock without geometry evidence"
    )
    expect(
      decision.dockScreen.displayID == right.displayID,
      "initial fallback must use pointer display"
    )
    expect(
      decision.detectionSource == .mouseLocationFallback,
      "initial hidden Dock must report fallback source"
    )
  }

  private static func testHiddenDockProcessWindowOverridesPointerFallback() {
    let main = display(
      id: 160,
      appKitFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
      windowFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
      isMain: true
    )
    let secondary = display(
      id: 170,
      appKitFrame: CGRect(x: -1920, y: 89, width: 1920, height: 1080),
      windowFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    )
    var uptime: TimeInterval = 0
    var dockHints = [
      window(
        owner: "Dock",
        name: "Wallpaper-secondary",
        bounds: secondary.frameWindowCoordinates,
        layer: -2_147_483_624
      ),
      window(
        owner: "Dock",
        name: "Wallpaper-main",
        bounds: main.frameWindowCoordinates,
        layer: -2_147_483_624
      ),
      window(
        owner: "Dock",
        name: "Dock",
        bounds: secondary.frameWindowCoordinates,
        layer: 20
      ),
    ]
    let evaluator = makeEvaluator(
      windows: { [] },
      dockDisplayHints: { dockHints },
      screens: { [main, secondary] },
      edge: .left,
      mouse: { CGPoint(x: 900, y: 500) },
      uptime: { uptime }
    )

    let hiddenDock = requireDecision(
      evaluator.evaluate(),
      context: "hidden Dock process window on secondary display"
    )
    expect(
      hiddenDock.dockScreen.displayID == secondary.displayID,
      "hidden Dock process window must override pointer fallback"
    )
    expect(
      hiddenDock.detectionSource == .dockProcessWindow,
      "hidden Dock process window must report its detection source"
    )

    dockHints = [
      window(
        owner: "Dock",
        name: "Dock",
        bounds: main.frameWindowCoordinates,
        layer: 20
      ),
    ]
    let cached = requireDecision(
      evaluator.evaluate(),
      context: "cached hidden Dock process display"
    )
    expect(
      cached.dockScreen.displayID == secondary.displayID,
      "expensive Dock process hint must remain cached within refresh interval"
    )

    uptime = 2
    let migrated = requireDecision(evaluator.evaluate(), context: "hidden Dock moved without topology event")
    expect(migrated.dockScreen.displayID == main.displayID,
      "hidden Dock display hints must refresh even without topology events")

    evaluator.invalidateCaches()
    let refreshed = requireDecision(
      evaluator.evaluate(),
      context: "hidden Dock process display after topology refresh"
    )
    expect(
      refreshed.dockScreen.displayID == main.displayID,
      "cache invalidation must refresh the hidden Dock process display"
    )
  }

  private static func testVisibleInsetOverridesProcessHint() {
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let main = display(id: 1, appKitFrame: frame, windowFrame: frame,
      visibleFrame: CGRect(x: 0, y: 60, width: 1000, height: 740))
    let otherFrame = frame.offsetBy(dx: 1000, dy: 0)
    let other = display(id: 2, appKitFrame: otherFrame, windowFrame: otherFrame)
    let evaluator = makeEvaluator(windows: { [] }, dockDisplayHints: {
      [window(owner: "Dock", name: "Dock", bounds: otherFrame, layer: 20)]
    }, screens: { [main, other] }, edge: .bottom,
      mouse: { CGPoint(x: 1500, y: 400) }, autoHide: false)
    let result = requireDecision(evaluator.evaluate(), context: "visible inset versus stale hint")
    expect(result.dockScreen.displayID == 1, "visible Dock evidence must outrank process hints")
    expect(result.detectionSource == .visibleFrameInset, "must report visible evidence")
  }

  private static func testAmbiguousProcessHintsUseFallback() {
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let otherFrame = frame.offsetBy(dx: 1000, dy: 0)
    let screens = [display(id: 1, appKitFrame: frame, windowFrame: frame),
      display(id: 2, appKitFrame: otherFrame, windowFrame: otherFrame)]
    let evaluator = makeEvaluator(windows: { [] }, dockDisplayHints: {
      screens.map { window(owner: "Dock", name: "Dock",
        bounds: $0.frameWindowCoordinates, layer: 20) }
    }, screens: { screens }, edge: .bottom, mouse: { CGPoint(x: 1500, y: 400) })
    let result = requireDecision(evaluator.evaluate(), context: "ambiguous hints")
    expect(result.dockScreen.displayID == 2, "ambiguous hints must not select the lowest display ID")
    expect(result.detectionSource == .mouseLocationFallback, "ambiguous hint must remain a fallback")
  }

  private static func testDockSpanIsClippedToDisplay() {
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let screen = display(id: 1, appKitFrame: frame, windowFrame: frame)
    let evaluator = makeEvaluator(windows: {
      [window(owner: "Dock", bounds: CGRect(x: -100, y: 750, width: 500, height: 50)),
       window(owner: "Editor", bounds: CGRect(x: -200, y: 740, width: 150, height: 60))]
    }, screens: { [screen] }, edge: .bottom, mouse: { CGPoint(x: 500, y: 400) })
    let result = requireDecision(evaluator.evaluate(), context: "partially offscreen Dock")
    expect(result.dockFrame.minX == 0 && result.dockFrame.maxX == 400,
      "Dock collision span must stay within its selected display")
    expect(!result.shouldAutoHide, "off-display window must not trigger hiding")
  }

  private static func testMalformedWindowBoundsAreIgnored() {
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let screen = display(id: 1, appKitFrame: frame, windowFrame: frame)
    let invalidBounds: [[String: Any]] = [
      ["X": 0, "Y": 700, "Width": -1000, "Height": 100],
      ["X": 0, "Y": 700, "Width": Double.infinity, "Height": 100],
      ["X": Double.nan, "Y": 700, "Width": 1000, "Height": 100],
      ["X": 0, "Y": 700, "Width": 1000, "Height": 0],
    ]
    let evaluator = makeEvaluator(windows: {
      invalidBounds.map { bounds in
        [kCGWindowOwnerName as String: "Dock", kCGWindowBounds as String: bounds]
      }
    }, screens: { [screen] }, edge: .bottom, mouse: { CGPoint(x: 500, y: 400) })
    let result = requireDecision(evaluator.evaluate(), context: "malformed window records")
    expect(result.detectionSource == .mouseLocationFallback, "invalid rectangles must not become Dock spans")
  }

  private static func testEngineLifecycle() {
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let screen = display(id: 1, appKitFrame: frame, windowFrame: frame)
    var hintReads = 0
    let evaluator = makeEvaluator(windows: { [] }, dockDisplayHints: {
      hintReads += 1
      return []
    }, screens: { [screen] }, edge: .bottom, mouse: { CGPoint(x: 500, y: 400) })
    let engine = SmartPolicyEngine(evaluator: evaluator)
    var reports = 0
    engine.onDecision = { _ in
      expect(Thread.isMainThread, "decisions must be delivered on the main thread")
      reports += 1
    }
    engine.refresh(reason: "beforeStart")
    expect(reports == 0 && hintReads == 0, "refresh must not evaluate a stopped engine")
    engine.start()
    engine.refresh(reason: "running")
    expect(reports == 1 && hintReads == 1, "running refresh must report immediately")
    engine.stop()
    engine.refresh(reason: "afterStop")
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    expect(reports == 1 && hintReads == 1, "cancelled timer and refresh must not report after stop")
    engine.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    engine.stop()
    expect(reports == 2 && hintReads == 2, "restart must clear deduplication and refresh geometry hints")
  }

  private static func testScreenRefreshPreservesMeasuredThickness() {
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    var hidden = false
    var screen = display(id: 1, appKitFrame: frame, windowFrame: frame,
      visibleFrame: CGRect(x: 0, y: 200, width: 1000, height: 800))
    let evaluator = makeEvaluator(windows: {
      [window(owner: "Editor", bounds: CGRect(x: 450, y: 810, width: 100, height: 20))]
    }, screens: { [screen] }, edge: .bottom, mouse: { CGPoint(x: 500, y: 500) })
    evaluator.isDockAutoHideEnabled = { hidden }
    let visible = requireDecision(evaluator.evaluate(), context: "visible measured thickness")
    expect(visible.shouldAutoHide, "window must overlap the measured Dock area")
    hidden = true
    screen = display(id: 1, appKitFrame: frame, windowFrame: frame)
    evaluator.invalidateCaches()
    let refreshed = requireDecision(evaluator.evaluate(), context: "screen notification after hiding")
    expect(refreshed.dockFrame.height == 200 && refreshed.shouldAutoHide,
      "visible-frame notification must preserve measured thickness to avoid hide/show oscillation")
  }

  private static func testOversizedDockHintIsRejected() {
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let otherFrame = frame.offsetBy(dx: 1000, dy: 0)
    let screens = [display(id: 1, appKitFrame: frame, windowFrame: frame),
      display(id: 2, appKitFrame: otherFrame, windowFrame: otherFrame)]
    let evaluator = makeEvaluator(windows: { [] }, dockDisplayHints: {
      [window(owner: "Dock", name: "Dock", bounds: frame.union(otherFrame), layer: 20)]
    }, screens: { screens }, edge: .bottom, mouse: { CGPoint(x: 1500, y: 400) })
    let result = requireDecision(evaluator.evaluate(), context: "Dock hint spanning two displays")
    expect(result.detectionSource == .mouseLocationFallback && result.dockScreen.displayID == 2,
      "a window covering multiple screens cannot identify a unique Dock display")
  }

  private static func testSizeChangesInvalidateHiddenGeometry() {
    typealias Size = DockWindowOverlapEvaluator.SizePreferences
    let initial = Size(tileSize: 40, magnificationEnabled: false, largeSize: 80)
    let changes = [
      Size(tileSize: 60, magnificationEnabled: false, largeSize: 80),
      Size(tileSize: 40, magnificationEnabled: true, largeSize: 80),
      Size(tileSize: 40, magnificationEnabled: false, largeSize: 100),
    ]
    for changed in changes {
      let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
      var screen = display(id: 1, appKitFrame: frame, windowFrame: frame,
        visibleFrame: CGRect(x: 0, y: 100, width: 1000, height: 700))
      var windows = [window(owner: "Dock", bounds: CGRect(x: 300, y: 700, width: 400, height: 100))]
      var sizes = initial
      var hidden = false
      let evaluator = DockWindowOverlapEvaluator(
        prefsClient: DockPreferencesClient(), windowListProvider: { windows },
        dockDisplayHintWindowListProvider: { [] }, screenProvider: { [screen] },
        dockEdgeProvider: { .bottom }, mouseLocationProvider: { CGPoint(x: 500, y: 400) },
        sizePreferencesProvider: { sizes })
      evaluator.isDockAutoHideEnabled = { hidden }
      let visible = requireDecision(evaluator.evaluate(), context: "size change setup")
      expect(visible.dockFrame.width == 400 && visible.dockFrame.height == 100,
        "setup must cache a measured Dock span and thickness")
      hidden = true
      windows = []
      screen = display(id: 1, appKitFrame: frame, windowFrame: frame)
      sizes = changed
      evaluator.invalidateCaches()
      let result = requireDecision(evaluator.evaluate(), context: "hidden Dock size changed")
      let iconSize = changed.magnificationEnabled ? max(changed.tileSize, changed.largeSize) : changed.tileSize
      expect(result.dockFrame.width == 1000 && result.dockFrame.height == iconSize + 12,
        "size changes must invalidate both span and thickness even across screen notifications")
    }
  }

  private static func makeEvaluator(
    windows: @escaping () -> [[String: Any]],
    dockDisplayHints: @escaping () -> [[String: Any]] = { [] },
    screens: @escaping () -> [DockDisplaySnapshot],
    edge: DockEdge,
    mouse: @escaping () -> CGPoint,
    autoHide: Bool = true,
    uptime: @escaping () -> TimeInterval = { 0 }
  ) -> DockWindowOverlapEvaluator {
    let evaluator = DockWindowOverlapEvaluator(
      prefsClient: DockPreferencesClient(),
      windowListProvider: windows,
      dockDisplayHintWindowListProvider: dockDisplayHints,
      screenProvider: screens,
      dockEdgeProvider: { edge },
      mouseLocationProvider: mouse,
      uptimeProvider: uptime
    )
    evaluator.isDockAutoHideEnabled = { autoHide }
    return evaluator
  }

  private static func owner(of window: [String: Any]) -> String? {
    window[kCGWindowOwnerName as String] as? String
  }

  private static func requireDecision(
    _ decision: DockOverlapDecision?,
    context: String
  ) -> DockOverlapDecision {
    guard let decision else {
      fatalError("Expected decision for \(context)")
    }
    return decision
  }

  private static func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) {
    precondition(condition(), message)
  }
}
