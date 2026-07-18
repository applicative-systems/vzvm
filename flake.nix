{
  description = "vzvm: a Linux builder for macOS Nix on Apple's Virtualization.framework, with Rosetta";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    inputs:
    let
      system = "aarch64-darwin";
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.self.overlays.default ];
      };
      inherit (pkgs) lib;
    in
    {
      overlays = {
        vzvm = import ./overlay.nix;
        default = inputs.self.overlays.vzvm;
      };

      nixosModules = {
        # The VM backend: gives a NixOS guest a `system.build.vm` on Virtualization.framework.
        default = ./modules/virtualisation/vz-vm.nix;

        vz-vm = ./modules/virtualisation/vz-vm.nix;
        vm-base = ./modules/virtualisation/vm-base.nix;

        # The remote-builder guest, split the way it could be split upstream.
        nix-builder = ./modules/profiles/nix-builder.nix;
        nix-builder-vz-vm = ./modules/profiles/nix-builder-vz-vm.nix;
      };

      packages.${system} = {
        default = pkgs.vzvm;
        inherit (pkgs) vzvm;
        inherit (pkgs.darwin) linux-builder-vz;

        # `nix run .#benchmark-full` -- the whole A/B session in one command.
        #
        # Must be run from the checkout: it drives bench/run.sh, which writes
        # results into the working tree. It also stops the nix-darwin builder for
        # the duration (all subjects collide with it on 31022) and restores it
        # from an EXIT trap.
        benchmark-full = pkgs.writeShellApplication {
          name = "benchmark-full";
          runtimeInputs = [
            # bench/run.sh is `#!/usr/bin/env bash` and needs mapfile, declare -A
            # and EPOCHREALTIME. macOS ships bash 3.2, which has none of them, so
            # a modern bash must be on PATH rather than left to chance.
            pkgs.bash
            pkgs.jq
            pkgs.python3
            pkgs.openssh
            pkgs.coreutils
            pkgs.findutils
            pkgs.git
          ];
          text = builtins.readFile ./bench/run-all.sh;
        };
      };

      formatter.${system} =
        let
          # Carried verbatim from nixpkgs for a pure-refactor upstream diff: whitespace only.
          excludeVendored = [ "modules/profiles/nix-builder.nix" ];
        in
        pkgs.treefmt.withConfig {
          settings = {
            tree-root-file = "flake.nix";
            on-unmatched = "info";
            formatter = {
              nixfmt = {
                command = lib.getExe pkgs.nixfmt;
                includes = [ "*.nix" ];
              };
              statix = {
                command = lib.getExe pkgs.statix;
                # Both are needed: `--ignore` for statix's own walk, `excludes` because it
                # ignores `--ignore` entirely when handed an explicit TARGET.
                options = [
                  "fix"
                  "--ignore"
                ]
                ++ excludeVendored;
                no-positional-arg-support = true;
                includes = [ "*.nix" ];
                excludes = excludeVendored;
              };
              deadnix = {
                command = lib.getExe pkgs.deadnix;
                options = [ "--edit" ];
                includes = [ "*.nix" ];
                # deadnix does receive a file list, so treefmt can filter it.
                excludes = excludeVendored;
              };
              swift-format = {
                command = lib.getExe pkgs.swift-format;
                options = [
                  "format"
                  "--in-place"
                ];
                includes = [ "*.swift" ];
              };
              prettier = {
                command = lib.getExe pkgs.prettier;
                options = [ "--write" ];
                includes = [
                  "*.json"
                  "*.md"
                  "*.yaml"
                  "*.yml"
                ];
              };
              shellcheck = {
                command = lib.getExe pkgs.shellcheck;
                includes = [
                  "*.sh"
                  "*.bash"
                  "*.envrc"
                ];
              };
              shfmt = {
                command = lib.getExe pkgs.shfmt;
                options = [
                  "-w"
                  "-i"
                  "2"
                  "-s"
                ];
                includes = [
                  "*.sh"
                  "*.bash"
                  "*.envrc"
                ];
              };
            };
          };
        };

      devShells.${system} = {
        default = pkgs.mkShell {
          packages = [
            pkgs.swift
            pkgs.swiftpm
            pkgs.swift-format
            pkgs.jq
            inputs.self.formatter.${system}
          ];
        };

        # `nix develop .#bench` then `bench/run.sh`. hyperfine is for ad-hoc one-offs only:
        # it cannot interleave two commands, so the harness cannot be built on it.
        bench = pkgs.mkShell {
          packages = [
            pkgs.jq
            pkgs.python3
            pkgs.hyperfine
            pkgs.openssh
          ];
        };
      };

      checks.${system} = {
        formatting = inputs.self.formatter.${system}.check inputs.self;
        inherit (pkgs) vzvm;
        # Booting needs Virtualization.framework, so only evaluation and the runner are checked.
        eval-smoke = pkgs.callPackage ./tests/eval-smoke.nix { };
        # The benchmark needs sudo and hours, so only its subjects' comparability is asserted.
        bench-parity = pkgs.callPackage ./tests/bench-parity.nix { };
        inherit (pkgs.darwin) linux-builder-vz;
      };
    };
}
