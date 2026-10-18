import Foundation
import XCTest

// As in vzvm: a peer that vanishes mid-write must surface as EPIPE, not kill the run.
signal(SIGPIPE, SIG_IGN)

// corelibs XCTest has no runtime discovery: every test is listed in its class's allTests.
XCTMain([
  testCase(ConfigTests.allTests),
  testCase(MachineTests.allTests),
  testCase(VsockProxyTests.allTests),
])
