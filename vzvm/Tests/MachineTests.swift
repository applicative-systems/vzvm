import XCTest

final class MachineTests: XCTestCase {
  static let allTests = [
    ("testAlwaysOnBootsAtLaunch", testAlwaysOnBootsAtLaunch),
    ("testAlwaysOnPowerOffExits", testAlwaysOnPowerOffExits),
    ("testOnDemandWaitsForFirstConnection", testOnDemandWaitsForFirstConnection),
    ("testConnectionsDuringBootShareOneBoot", testConnectionsDuringBootShareOneBoot),
    ("testIdleTimeoutStopsGuest", testIdleTimeoutStopsGuest),
    ("testConnectionCancelsIdleTimer", testConnectionCancelsIdleTimer),
    ("testIdleTimerWaitsForLastConnection", testIdleTimerWaitsForLastConnection),
    ("testClientGoneDuringBootArmsIdleTimer", testClientGoneDuringBootArmsIdleTimer),
    ("testStoppedGuestStaysDownWithoutConnections", testStoppedGuestStaysDownWithoutConnections),
    ("testConnectionDuringShutdownBootsAgain", testConnectionDuringShutdownBootsAgain),
    ("testTerminateWhileStoppedExits", testTerminateWhileStoppedExits),
    ("testTerminateWhileRunningRequestsStop", testTerminateWhileRunningRequestsStop),
    ("testTerminateWhileStartingWaitsForStart", testTerminateWhileStartingWaitsForStart),
    ("testTerminateWhileStoppingWaitsForPowerOff", testTerminateWhileStoppingWaitsForPowerOff),
    ("testTerminateDuringShutdownDoesNotBootAgain", testTerminateDuringShutdownDoesNotBootAgain),
    ("testNoBootAfterTerminate", testNoBootAfterTerminate),
    ("testPowerButtonRepeatsUntilGuestStops", testPowerButtonRepeatsUntilGuestStops),
    ("testUnheededStopIsForced", testUnheededStopIsForced),
    ("testGuestThatCannotBeAskedIsForced", testGuestThatCannotBeAskedIsForced),
    ("testFailedStopRequestIsForced", testFailedStopRequestIsForced),
    ("testFailedForceStopExits", testFailedForceStopExits),
    ("testStartFailureExits", testStartFailureExits),
    ("testConfigurationFailureExits", testConfigurationFailureExits),
    ("testGuestErrorExits", testGuestErrorExits),
    ("testStaleStopErrorSparesNewGuest", testStaleStopErrorSparesNewGuest),
    ("testStaleCrashSparesNewGuest", testStaleCrashSparesNewGuest),
    ("testStaleStartFailureSparesNewGuest", testStaleStartFailureSparesNewGuest),
    ("testConnectReachesGuestOnlyWhileRunning", testConnectReachesGuestOnlyWhileRunning),
  ]

  // MARK: Booting

  func testAlwaysOnBootsAtLaunch() {
    let h = Harness(idleTimeoutSeconds: nil)
    h.launch()
    XCTAssertEqual(h.guests.count, 1)
  }

  func testAlwaysOnPowerOffExits() {
    let h = Harness(idleTimeoutSeconds: nil)
    h.launch()
    h.started()
    h.poweredOff()
    XCTAssertEqual(h.exitCodes, [ExitCode.ok])
    XCTAssertEqual(h.guests.count, 1)
  }

  func testOnDemandWaitsForFirstConnection() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    XCTAssertEqual(h.guests.count, 0)
    h.open()
    XCTAssertEqual(h.guests.count, 1)
  }

  func testConnectionsDuringBootShareOneBoot() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    h.open()
    h.open()
    h.started()
    h.open()
    XCTAssertEqual(h.guests.count, 1)
  }

  // MARK: Idle timer

  func testIdleTimeoutStopsGuest() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.advance(59)
    XCTAssertEqual(h.guest.stopRequests, 0)
    h.advance(1)
    XCTAssertEqual(h.guest.stopRequests, 1)
    XCTAssertEqual(h.exitCodes, [])
  }

  func testConnectionCancelsIdleTimer() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.advance(30)
    h.open()
    h.advance(600)
    XCTAssertEqual(h.guest.stopRequests, 0)
  }

  func testIdleTimerWaitsForLastConnection() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    h.open()
    h.open()
    h.started()
    h.close()
    h.advance(600)
    XCTAssertEqual(h.guest.stopRequests, 0)
    h.close()
    h.advance(60)
    XCTAssertEqual(h.guest.stopRequests, 1)
  }

  /// The connection that woke the guest is gone before it is up: nothing would ever close
  /// a connection afterwards, so the start itself must arm the timer.
  func testClientGoneDuringBootArmsIdleTimer() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    h.open()
    h.close()
    h.started()
    h.advance(60)
    XCTAssertEqual(h.guest.stopRequests, 1)
  }

  func testStoppedGuestStaysDownWithoutConnections() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.advance(60)
    h.poweredOff()
    XCTAssertEqual(h.guests.count, 1)
    XCTAssertEqual(h.exitCodes, [])
    h.open()
    XCTAssertEqual(h.guests.count, 2)
  }

  /// A connection that arrives while the guest shuts down cannot be served by it; it waits
  /// for the next boot.
  func testConnectionDuringShutdownBootsAgain() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.advance(60)
    h.open()
    XCTAssertEqual(h.guests.count, 1)
    h.poweredOff()
    XCTAssertEqual(h.guests.count, 2)
    XCTAssertEqual(h.exitCodes, [])
  }

  // MARK: Terminating

  func testTerminateWhileStoppedExits() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    h.terminate()
    XCTAssertEqual(h.exitCodes, [ExitCode.ok])
  }

  func testTerminateWhileRunningRequestsStop() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.terminate()
    XCTAssertEqual(h.guest.stopRequests, 1)
    XCTAssertEqual(h.exitCodes, [])
    h.poweredOff()
    XCTAssertEqual(h.exitCodes, [ExitCode.ok])
  }

  /// VZ rejects stopping a starting guest; this used to exit with a runtime error.
  func testTerminateWhileStartingWaitsForStart() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    h.open()
    h.terminate()
    XCTAssertEqual(h.guest.stopRequests, 0)
    XCTAssertEqual(h.guest.forcedStops, 0)
    h.started()
    // A guest this fresh would ignore ACPI, so no point in asking.
    XCTAssertEqual(h.guest.stopRequests, 0)
    XCTAssertEqual(h.guest.forcedStops, 1)
    h.forceStopCompleted()
    XCTAssertEqual(h.exitCodes, [ExitCode.ok])
  }

  func testTerminateWhileStoppingWaitsForPowerOff() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.advance(60)
    h.terminate()
    XCTAssertEqual(h.guest.stopRequests, 1)
    XCTAssertEqual(h.exitCodes, [])
    h.poweredOff()
    XCTAssertEqual(h.exitCodes, [ExitCode.ok])
  }

  func testTerminateDuringShutdownDoesNotBootAgain() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.advance(60)
    h.open()
    h.terminate()
    h.poweredOff()
    XCTAssertEqual(h.guests.count, 1)
    XCTAssertEqual(h.exitCodes, [ExitCode.ok])
  }

  func testNoBootAfterTerminate() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    h.terminate()
    h.open()
    XCTAssertEqual(h.guests.count, 0)
  }

  // MARK: Stopping

  /// A guest still booting drops the ACPI press until logind is up.
  func testPowerButtonRepeatsUntilGuestStops() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.terminate()
    XCTAssertEqual(h.guest.stopRequests, 1)
    h.advance(Machine.powerButtonIntervalSeconds)
    XCTAssertEqual(h.guest.stopRequests, 2)
    h.advance(Machine.powerButtonIntervalSeconds)
    XCTAssertEqual(h.guest.stopRequests, 3)
    h.poweredOff()
    h.advance(Machine.stopGraceSeconds)
    XCTAssertEqual(h.guest.stopRequests, 3)
    XCTAssertEqual(h.guest.forcedStops, 0)
  }

  func testUnheededStopIsForced() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.terminate()
    h.advance(Machine.stopGraceSeconds - 1)
    XCTAssertEqual(h.guest.forcedStops, 0)
    h.advance(1)
    XCTAssertEqual(h.guest.forcedStops, 1)
    h.forceStopCompleted()
    XCTAssertEqual(h.exitCodes, [ExitCode.ok])
  }

  func testGuestThatCannotBeAskedIsForced() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.guest.canRequestStop = false
    h.terminate()
    XCTAssertEqual(h.guest.stopRequests, 0)
    XCTAssertEqual(h.guest.forcedStops, 1)
    h.forceStopCompleted()
    XCTAssertEqual(h.exitCodes, [ExitCode.ok])
  }

  func testFailedStopRequestIsForced() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.guest.requestStopError = FakeError()
    h.terminate()
    XCTAssertEqual(h.guest.forcedStops, 1)
  }

  func testFailedForceStopExits() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.guest.canRequestStop = false
    h.terminate()
    h.forceStopCompleted(FakeError())
    XCTAssertEqual(h.exitCodes, [ExitCode.runtime])
  }

  // MARK: Failures

  func testStartFailureExits() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    h.open()
    h.failedToStart()
    XCTAssertEqual(h.exitCodes, [ExitCode.runtime])
  }

  func testConfigurationFailureExits() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.configureError = FakeError()
    h.launch()
    h.open()
    XCTAssertEqual(h.exitCodes, [ExitCode.runtime])
  }

  func testGuestErrorExits() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.crashed()
    XCTAssertEqual(h.exitCodes, [ExitCode.guestError])
  }

  // MARK: Replaced guests

  /// The forced stop lost the race against a poweroff, and a waiting connection has booted
  /// the next guest by the time the stop reports its failure.
  func testStaleStopErrorSparesNewGuest() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.advance(60)
    h.open()
    h.advance(Machine.stopGraceSeconds)
    let old = h.guest
    XCTAssertEqual(old.forcedStops, 1)
    h.poweredOff()
    XCTAssertEqual(h.guests.count, 2)
    h.queue.sync { old.stopCompletion?(FakeError()) }
    XCTAssertEqual(h.exitCodes, [])
  }

  func testStaleCrashSparesNewGuest() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.runningIdle()
    h.advance(60)
    h.open()
    let old = h.guest
    h.poweredOff()
    XCTAssertEqual(h.guests.count, 2)
    h.queue.sync { old.onStop?(FakeError()) }
    XCTAssertEqual(h.exitCodes, [])
  }

  func testStaleStartFailureSparesNewGuest() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    h.open()
    let old = h.guest
    h.poweredOff()
    XCTAssertEqual(h.guests.count, 2)
    h.queue.sync { old.startCompletion?(.failure(FakeError())) }
    XCTAssertEqual(h.exitCodes, [])
  }

  // MARK: Vsock

  /// A starting or stopping guest must not be handed connections: the proxy retries instead.
  func testConnectReachesGuestOnlyWhileRunning() {
    let h = Harness(idleTimeoutSeconds: 60)
    h.launch()
    h.open()
    XCTAssertNil(try? h.connect(toPort: 22)?.get())
    XCTAssertEqual(h.guest.connectedPorts, [])
    h.started()
    _ = h.connect(toPort: 22)
    XCTAssertEqual(h.guest.connectedPorts, [22])
    h.close()
    h.advance(60)
    XCTAssertNil(try? h.connect(toPort: 22)?.get())
    XCTAssertEqual(h.guest.connectedPorts, [22])
  }
}
