# Asserts the benchmark subjects are actually comparable.
#
# The failure mode this guards against is silent: if a future change to either
# backend's defaults unbalances cores or memory, the benchmark still runs, still
# produces a clean-looking table, and the table is wrong. Cheap to check at eval
# time, expensive to notice after publishing.
#
# Like tests/eval-smoke.nix this stops at evaluation -- booting needs
# Virtualization.framework and cannot run in a Nix sandbox.
{
  lib,
  pkgs,
  runCommand,
}:
let
  subjects = import ../bench/subjects.nix { inherit pkgs; };
  inherit (subjects) configs;

  # Compared pairwise below; anything unequal here invalidates every ratio the
  # harness produces.
  resourcesOf = c: {
    cores = c.virtualisation.cores;
    memorySize = c.virtualisation.memorySize;
    diskSize = c.virtualisation.diskSize;
  };

  a1 = resourcesOf configs.a1;
  b = resourcesOf configs.b;

  fmt = r: "cores=${toString r.cores} mem=${toString r.memorySize} disk=${toString r.diskSize}";

  # Both subjects must advertise x86_64-linux, or the headline workload silently
  # routes to only one of them.
  platformsOf = c: c.nix.settings.extra-platforms or [ ];
in
runCommand "bench-parity"
  {
    meta.description = "Benchmark subjects are resource-matched and both build x86_64-linux";
  }
  ''
    ${lib.optionalString (a1 != b) ''
      echo "benchmark subjects are not resource-matched:" >&2
      echo "  a1: ${fmt a1}" >&2
      echo "  b : ${fmt b}" >&2
      exit 1
    ''}

    ${lib.optionalString (!lib.elem "x86_64-linux" (platformsOf configs.a1)) ''
      echo "a1 does not advertise x86_64-linux; the binfmt opt-in regressed" >&2
      exit 1
    ''}

    ${lib.optionalString (!lib.elem "x86_64-linux" (platformsOf configs.b)) ''
      echo "b does not advertise x86_64-linux; Rosetta support regressed" >&2
      exit 1
    ''}

    # A1 must reach x86_64 through binfmt emulation and B must not: that
    # difference is the entire experiment.
    ${lib.optionalString (configs.a1.boot.binfmt.emulatedSystems == [ ]) ''
      echo "a1 has no emulatedSystems; it would not be using qemu-user" >&2
      exit 1
    ''}
    ${lib.optionalString (configs.b.boot.binfmt.emulatedSystems != [ ]) ''
      echo "b gained binfmt emulation; it would no longer be measuring Rosetta" >&2
      exit 1
    ''}

    echo "resource-matched: ${fmt a1}" > $out
  ''
