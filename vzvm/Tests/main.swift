import XCTest

// corelibs XCTest has no runtime discovery: every test is listed in its class's allTests.
XCTMain([
  testCase(ConfigTests.allTests),
  testCase(MachineTests.allTests),
])
