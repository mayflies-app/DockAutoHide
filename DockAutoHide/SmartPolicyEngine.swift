import Foundation

@MainActor
final class SmartPolicyEngine {
  var onDecision: ((DockOverlapDecision) -> Void)?

  let evaluator: DockWindowOverlapEvaluator
  private var timer: DispatchSourceTimer?

  private var lastReported: Bool?

  private let interval: TimeInterval = 0.1

  init(evaluator: DockWindowOverlapEvaluator) {
    self.evaluator = evaluator
  }

  deinit {
    timer?.cancel()
  }

  func start() {
    stop()
    evaluator.invalidateCaches(resetTracking: true)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: interval)
    timer.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.tick() }
    }
    timer.resume()
    self.timer = timer
  }

  func stop() {
    timer?.cancel()
    timer = nil
    lastReported = nil
  }

  func refresh(reason: String) {
    guard timer != nil else { return }
    evaluator.invalidateCaches()
    tick(forceReport: true, triggerReason: reason)
  }

  private func tick(
    forceReport: Bool = false,
    triggerReason: String? = nil
  ) {
    guard timer != nil, let decision = evaluator.evaluate() else {
      return
    }

    if forceReport || lastReported != decision.shouldAutoHide {
      lastReported = decision.shouldAutoHide
      DockLogger
        .log(
          "Smart decision: autohide=\(decision.shouldAutoHide), reason=\(decision.reason), source=\(decision.detectionSource.rawValue), trigger=\(triggerReason ?? "timer")"
        )
      onDecision?(decision)
    }
  }
}
