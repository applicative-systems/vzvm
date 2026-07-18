// swift-tools-version:5.9
import PackageDescription

// zero external dependencies (Foundation + Virtualization only), so that
// packaging in nixpkgs needs no swiftpm2nix
let package = Package(
  name: "vzvm",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(name: "vzvm", path: "Sources/vzvm")
  ]
)
