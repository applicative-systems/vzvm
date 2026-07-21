{
  lib,
  darwin,
  swift,
  swiftPackages,
}:

swiftPackages.stdenv.mkDerivation {
  pname = "vzvm";
  version = "1.0.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Package.swift
      ./Sources
    ];
  };

  nativeBuildInputs = [
    swift
    darwin.sigtool
  ];

  # We use no external dependencies to avoid swiftpm2nix and network-fetching `swift build`
  buildPhase = ''
    runHook preBuild

    swiftc -O -o vzvm Sources/vzvm/*.swift

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 vzvm $out/bin/vzvm

    runHook postInstall
  '';

  # Virtualization.framework refuses to create a VM unless the binary has entitlement
  postFixup = ''
    codesign --entitlements ${./vzvm.entitlements} -f -s - $out/bin/vzvm
  '';

  meta = {
    description = "Minimal Linux VM monitor built on Apple's Virtualization.framework";
    longDescription = ''
      vzvm boots a Linux guest from a kernel and initrd on Apple's
      Virtualization.framework, configured from a JSON file. It supports
      Rosetta directory shares for running x86_64 binaries on Apple silicon, and
      forwards host TCP ports into the guest over vsock, so inbound connections need
      no guest IP discovery.
    '';
    homepage = "https://github.com/applicative-systems/vzvm";
    license = lib.licenses.mit;

    # Rosetta and the arm64 direct kernel boot make this Apple-silicon only.
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.fromSource ];
    mainProgram = "vzvm";
  };
}
