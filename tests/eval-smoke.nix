# Evaluates a minimal vz guest and asserts the shape of what the module renders.
{
  lib,
  path,
  runCommand,
  pkgs,
}:

let
  guestSystem = "aarch64-linux";

  mkMachine =
    extra:
    import (path + "/nixos/lib/eval-config.nix") {
      system = guestSystem;
      modules = [
        ../modules/virtualisation/vz-vm.nix
        {
          virtualisation.host.pkgs = pkgs;
          virtualisation.cores = 2;
          virtualisation.memorySize = 2048;
          virtualisation.vz.forwardPorts = [
            {
              host.port = 31022;
              guest.port = 22;
            }
          ];
          networking.hostName = "vz-smoke";
          documentation.enable = false;
          system.stateVersion = lib.trivial.release;
        }
        extra
      ];
    };

  machine = mkMachine { };

  # Only `file` carries a path. Rendering the console used to fall through an if/else that
  # turned any unrecognised mode into `file`, which nothing caught.
  consoleMachines = {
    stdio = {
      machine = mkMachine { };
      filter = ''.console == { mode: "stdio" }'';
    };
    log = {
      machine = mkMachine { virtualisation.vz.console = "log"; };
      filter = ''.console == { mode: "log" }'';
    };
    file = {
      machine = mkMachine {
        virtualisation.vz.console = "file";
        virtualisation.vz.consoleLog = "./guest.log";
      };
      filter = ''.console == { mode: "file", path: "./guest.log" }'';
    };
  };

  # jq filters
  configAssertions = {
    "boots directly from a kernel" = ''.kernel | startswith("/nix/store")'';
    "supplies an initrd" = ''.initrd | startswith("/nix/store")'';
    "uses the virtio console" = ''.cmdline | contains("console=hvc0")'';
    "registers the closure from the command line" = ''.cmdline | contains("regInfo=")'';
    "honours the requested cpu count" = ".cpuCount == 2";
    "honours the requested memory" = ".memorySizeMiB == 2048";
    # Inbound SSH goes over vsock: NAT leaves the guest no stable inbound address.
    "forwards the host port to a vsock port" = ''
      .vsock.forwards[0].listen == "127.0.0.1:31022" and .vsock.forwards[0].vsockPort == 22
    '';
    # Pins the pruned schema: vzvm rejects unknown keys, so re-growing one fails at load.
    "enables rosetta as a plain flag" = ".rosetta == true";
    "does not emit a network object" = ".network == null";
  };

  runnerAssertions = {
    "builds a content-addressed store image" = "mkfs.erofs";
    "caches the store image by closure" = "store-";
    # The config path is the binary's entire interface: no flags, one argument.
    "invokes vzvm with the generated config" = ''/bin/vzvm "$config"'';
  };
in
runCommand "vz-eval-smoke"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    script=${machine.config.system.build.vm}/bin/run-${machine.config.networking.hostName}-vm

    config=$(grep -o '/nix/store/[a-z0-9]*-vzvm-config.json' "$script" | head -1)
    if [ -z "$config" ]; then
      echo "FAIL: runner does not reference a generated vzvm config" >&2
      exit 1
    fi

    echo "--- generated config ---"
    jq . "$config"

    fail=0

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (description: filter: ''
        if jq -e ${lib.escapeShellArg filter} "$config" > /dev/null; then
          echo "ok: ${description}"
        else
          echo "FAIL: ${description}" >&2
          fail=1
        fi
      '') configAssertions
    )}

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (description: needle: ''
        if grep -qF -- ${lib.escapeShellArg needle} "$script"; then
          echo "ok: ${description}"
        else
          echo "FAIL: ${description} (no ${needle} in runner)" >&2
          fail=1
        fi
      '') runnerAssertions
    )}

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (mode: spec: ''
        modeScript=${spec.machine.config.system.build.vm}/bin/run-${spec.machine.config.networking.hostName}-vm
        modeConfig=$(grep -o '/nix/store/[a-z0-9]*-vzvm-config.json' "$modeScript" | head -1)
        if jq -e ${lib.escapeShellArg spec.filter} "$modeConfig" > /dev/null; then
          echo "ok: console mode ${mode} renders exactly"
        else
          echo "FAIL: console mode ${mode} rendered $(jq -c .console "$modeConfig")" >&2
          fail=1
        fi
      '') consoleMachines
    )}

    # Runtime-resolved values must not be frozen into the evaluated config.
    for key in disks shares; do
      if [ "$(jq -r --arg k "$key" 'has($k)' "$config")" != "false" ]; then
        echo "FAIL: .$key should be filled in by the runner, not at evaluation time" >&2
        fail=1
      else
        echo "ok: .$key is left to the runner"
      fi
    done

    [ $fail -eq 0 ] || exit 1
    touch $out
  ''
