final: prev: {
  vzvm = final.callPackage ./vzvm { };

  darwin = prev.darwin.overrideScope (
    _: _: {
      # Mirror shape of `pkgs.darwin.linux-builder`
      linux-builder-vz = final.lib.makeOverridable (
        { modules }:
        let
          nixos = import (final.path + "/nixos") {
            configuration = {
              imports = [
                ./modules/profiles/nix-builder-vz-vm.nix
              ]
              ++ modules;

              virtualisation.host = {
                pkgs = final;
              };

              # aarch64-darwin is the only supported host, so the guest is fixed too.
              nixpkgs.hostPlatform = final.lib.mkDefault "aarch64-linux";
            };
            system = null;
          };
        in
        nixos.config.system.build.macos-builder-installer
      ) { modules = [ ]; };
    }
  );
}
