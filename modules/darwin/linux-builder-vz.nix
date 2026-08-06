# Host-side companion to the guest's `virtualisation.vz.vsockNixDaemon`: keeps the guest
# option, the forwarded socket and the build machine entry pointing at the same path.
#
# The machine URI is `ssh-ng://localhost?remote-program=<bridge>` rather than `unix://`:
# Nix's `unix://` store is a `LocalFSStore` that reads store objects from the *host's*
# filesystem, which is wrong when the daemon socket leads into a VM. `ssh-ng` streams
# everything over the daemon protocol, and the `localhost` authority engages `fakeSSH`
# in Nix's SSHMaster — no ssh subprocess; Nix execs the remote-program directly.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nix.linux-builder-vz.directDaemon;
  builderCfg = config.nix.linux-builder;

  bridge = pkgs.writeShellScript "linux-builder-vz-bridge" ''
    # Nix appends `--stdio`; the arguments are irrelevant, the socket is the endpoint.
    exec ${lib.getExe pkgs.socat} - UNIX-CONNECT:${cfg.socketPath}
  '';
in
{
  options.nix.linux-builder-vz.directDaemon = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Talk to the Linux builder's Nix daemon directly over vsock instead of
        through sshd: the build machine entry becomes a store URI that pipes
        the daemon protocol into a unix socket vzvm splices into the guest,
        where systemd hands each connection its own `nix-daemon --stdio`.
        This skips ssh and its per-connection handshake entirely; sshd stays
        available on port 31022 for interactive debugging.

        Note: this replaces `nix.buildMachines` wholesale — nix-darwin's ssh
        entry cannot be suppressed individually. Machines you define yourself
        must be re-added with a priority above `mkForce`.
      '';
    };

    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "${builderCfg.workingDirectory}/nix-daemon.sock";
      defaultText = lib.literalExpression ''"''${config.nix.linux-builder.workingDirectory}/nix-daemon.sock"'';
      description = ''
        Host unix socket the bridge connects to. Created by vzvm, owner-only —
        which means root, as the builder runs as a launchd daemon.
      '';
    };

    vsockPort = lib.mkOption {
      type = lib.types.port;
      default = 23;
      description = "Guest vsock port serving the Nix daemon protocol.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.linux-builder.config = {
      virtualisation.vz.vsockNixDaemon = {
        enable = true;
        port = cfg.vsockPort;
      };
      virtualisation.darwin-builder.daemonSocketPath = cfg.socketPath;
    };

    nix.buildMachines = lib.mkForce [
      {
        protocol = "ssh-ng";
        # The query parameter rides in hostName: nix-darwin's `protocol` enum ends
        # at the scheme, and the machines file wants the URI in one field anyway.
        hostName = "localhost?remote-program=${bridge}";
        sshUser = null;
        sshKey = null;
        publicHostKey = null;
        inherit (builderCfg)
          mandatoryFeatures
          maxJobs
          speedFactor
          supportedFeatures
          systems
          ;
      }
    ];
  };
}
