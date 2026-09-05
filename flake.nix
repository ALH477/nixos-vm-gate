{
  description = "vm-gate — validate a NixOS generation in a throwaway VM, then activate that exact closure";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules.vm-gate = import ./modules/vm-gate.nix;
      nixosModules.default = self.nixosModules.vm-gate;

      # A self-contained host so the gate can be exercised before it is trusted
      # with a real machine:
      #
      #   nix build github:ALH477/nixos-vm-gate#demo-vm
      #   export VM_GATE_DIR=$(mktemp -d)
      #   ./result/bin/run-*-vm        # boots, activates, self-checks, powers off
      #   cat "$VM_GATE_DIR/result"    # 0 = clean
      packages = forAllSystems (
        system: pkgs: {
          demo-vm =
            (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.vm-gate
                (
                  { lib, ... }:
                  {
                    boot.loader.grub.devices = [ "nodev" ];
                    fileSystems."/" = {
                      device = "/dev/vda1";
                      fsType = "ext4";
                    };
                    networking.hostName = "vm-gate-demo";
                    system.stateVersion = lib.trivial.release;

                    demod.vmGate = {
                      enable = true;
                      checks.store = "test -d /nix/store";
                    };
                  }
                )
              ];
            }).config.system.build.vm;
        }
      );

      formatter = forAllSystems (system: pkgs: pkgs.nixfmt-rfc-style or pkgs.nixpkgs-fmt);
    };
}
