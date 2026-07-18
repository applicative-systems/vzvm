# The builder VMs under comparison, pinned to identical resources.
#
# Both upstream and vz default to `virtualisation.cores = 1` (vm-base.nix:27 here,
# qemu-vm.nix upstream). A comparison at the defaults is therefore fair but
# single-core, which is not how anyone runs a builder. Everything is pinned
# explicitly instead, so a future default change cannot silently unbalance a run.
#
# Each subject gets its own hostPort and workingDirectory: all three ship the same
# committed SSH host key and would otherwise collide on 31022 and
# /var/lib/linux-builder. Distinct ports mean a stale VM is a connection refusal
# rather than a silently reused subject.
{
  pkgs,
  cores ? 8,
  memorySize ? 8192,
  diskSize ? 40960,
  stateDir ? "/tmp/vzvm-bench",
}:
let
  # Resource pinning applied identically to every subject. Kept separate from the
  # per-subject deltas below so the diff between subjects is only ever the backend.
  pinned = hostPort: name: {
    virtualisation.cores = cores;
    virtualisation.darwin-builder = {
      inherit memorySize diskSize hostPort;
      workingDirectory = "${stateDir}/${name}";
    };
    # The guest's own scheduling, which is distinct from the host daemon's.
    nix.settings = {
      inherit cores;
      max-jobs = cores;
    };
  };
in
{
  # A1 -- upstream QEMU builder with x86_64 opted in via binfmt (qemu-user, TCG)
  # inside an HVF-accelerated aarch64 guest.
  #
  # This is the only apples-to-apples comparator for B on x86_64: same guest
  # architecture, same hypervisor acceleration, only the x86 translation layer
  # differs. Stock `darwin.linux-builder` sets no binfmt and no extra-platforms,
  # so it cannot build x86_64-linux at all -- that capability gap is a separate
  # finding from any speed ratio, and must be reported as such.
  a1 = pkgs.darwin.linux-builder.override {
    modules = [
      (pinned 31023 "a1")
      { boot.binfmt.emulatedSystems = [ "x86_64-linux" ]; }
    ];
  };

  # A2 -- upstream's full x86_64-linux guest under qemu-system-x86_64, with no
  # HVF acceleration at all. Whole-system TCG.
  #
  # Reported only as a footnote. Quoting a ratio against A2 while describing A1's
  # mechanism is the single biggest integrity risk in this comparison.
  a2 = pkgs.darwin.linux-builder-x86_64.override {
    modules = [ (pinned 31024 "a2") ];
  };

  # B -- this repo. aarch64 guest under Virtualization.framework, x86_64 via Rosetta.
  b = pkgs.darwin.linux-builder-vz.override {
    modules = [ (pinned 31025 "b") ];
  };

  # The guest configurations behind the three installers, exposed so that
  # tests/bench-parity.nix can assert the subjects are actually comparable
  # without booting anything. A benchmark that silently compared 1 core against 8
  # would still produce a clean-looking table, so this is checked in CI.
  configs =
    let
      eval =
        modules:
        (import (pkgs.path + "/nixos/lib/eval-config.nix") {
          system = "aarch64-linux";
          inherit modules;
        }).config;
    in
    {
      a1 = eval [
        (pkgs.path + "/nixos/modules/profiles/nix-builder-vm.nix")
        (pinned 31023 "a1")
        { boot.binfmt.emulatedSystems = [ "x86_64-linux" ]; }
      ];
      b = eval [
        ../modules/profiles/nix-builder-vz-vm.nix
        (pinned 31025 "b")
      ];
    };
}
