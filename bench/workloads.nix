# Benchmark workloads: real packages, forced to miss every cache.
#
# `overrideAttrs` adding a SALT env var changes the derivation's environment and
# so its hash, forcing a rebuild -- but it does not touch buildInputs, so every
# dependency keeps its original drv path and stays substitutable. That is the
# property we need: rebuild exactly one package, fetch the rest.
#
# Two rules the harness depends on:
#   - Never salt a fixed-output derivation (fetchurl and friends). The output hash
#     is pinned, so the salt changes nothing and the "cache miss" is a no-op.
#   - Never salt anything stdenv-adjacent (gcc, binutils). That mass-rebuilds the
#     world and you are no longer timing the workload.
#
# `nixpkgs` is passed in deliberately rather than taken from the flake's own input:
# published numbers must name a fixed rev, and `nix flake update` must not be able
# to silently change what "build openssl" means.
{
  nixpkgs,
  salt,
  system ? "aarch64-linux",
  churnCount ? 300,
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  salted =
    pkg:
    pkg.overrideAttrs (_: {
      SALT = salt;
    });
in
{
  # W0 -- calibration probe, not a headline number.
  #
  # Pure compute, ~zero dependencies, runs in seconds. Its job is to detect
  # thermal drift: run it immediately before each timed workload and discard any
  # A/B pair whose two probe times disagree by more than the declared threshold.
  # This gives a drift-rejection rule fixed in advance, rather than post-hoc
  # outlier removal, which is how benchmarks lie.
  w0 = pkgs.runCommand "bench-probe-${salt}" { SALT = salt; } ''
    # Deterministic input, no /dev/urandom: the work must be identical every run.
    #
    # Read straight from /dev/zero rather than `yes | head -c`: `head` closing the
    # pipe sends SIGPIPE to `yes`, and stdenv runs builders under `pipefail`, so
    # that idiom fails the build rather than producing data.
    head -c 67108864 /dev/zero > data
    for _ in $(seq 8); do sha256sum data > /dev/null; done
    echo done > $out
  '';

  # W1 -- small, C, CMake, compile-bound, few deps. The fast "is my setup right"
  # workload, and the one to iterate on while developing the harness.
  w1 = salted pkgs.zstd;

  # W2 -- perl-driven configure, many small compiles, heavy process spawning.
  # Process startup is where translation overhead concentrates, so this is where
  # Rosetta's advantage over qemu-user should be largest. Expect the widest ratio.
  w2 = salted pkgs.openssl;

  # W3 -- many small files, link-heavy, more I/O than compute. The I/O control:
  # if B and A differ here but not in W1, the delta is virtio-blk/erofs, not
  # translation, and must not be attributed to Rosetta.
  w3 = salted pkgs.git;

  # W4 -- deliberately adversarial to Rosetta: large, long, and full of
  # hand-written x86 SIMD assembly. Rosetta's AVX coverage is limited, so this may
  # be slow or may fail outright. Either outcome is a result and goes in the table
  # at the same size as the wins.
  w4 = salted pkgs.ffmpeg;

  # subst -- substitution throughput: a wide closure of many small paths, fetched
  # from cache.nixos.org into a *wiped* guest store.
  #
  # Deliberately NOT salted. Salting would force a build, and the whole point is
  # to measure fetching: hundreds of small NARs, each its own HTTPS request. That
  # is where QEMU's SLiRP user-mode networking is expected to hurt most, and it is
  # the case that motivated this axis -- a derivation with many small dependencies
  # feeling far slower than its compute cost explains.
  #
  # Breadth matters more than size here: many small paths exercise per-connection
  # and per-path overhead, which is the suspected bottleneck, rather than raw
  # bandwidth.
  subst = pkgs.buildEnv {
    name = "bench-subst-closure";
    paths = with pkgs; [
      git
      python3
      cmake
      pkg-config
      ninja
      meson
      curl
      openssl
      sqlite
      libxml2
      imagemagick
      ffmpeg
      graphviz
      gnuplot
      texinfo
      perl
      ruby
      lua
      tcl
      zlib
    ];
  };

  # churn -- many tiny derivations, all built locally with nothing to fetch.
  #
  # This measures scheduling and connection overhead rather than compute or
  # bandwidth. It is the axis where the vz backend may *lose*: its sshd is
  # socket-activated with `Accept = true`, forking a fresh `sshd -i` per
  # connection, where the QEMU guest runs a persistent sshd. The `MaxConnections
  # = 512` comment in vz-vm.nix exists because that design already caused a hang
  # once, so it deserves a number rather than an assumption.
  #
  # Each unit is salted, so none can ever be substituted or reused across runs.
  churn =
    let
      units = lib.genList (
        i:
        pkgs.runCommand "bench-churn-${salt}-${toString i}" { SALT = salt; } ''
          echo ${toString i} > $out
        ''
      ) churnCount;
    in
    # Passing the list as an env var puts every unit in the aggregate's string
    # context, so realising this one derivation realises all of them.
    pkgs.runCommand "bench-churn-${salt}" { inherit units; } ''
      echo "$units" > $out
    '';
}
