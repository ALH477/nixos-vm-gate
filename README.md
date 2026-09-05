# vm-gate

[![ci](https://github.com/ALH477/nixos-vm-gate/actions/workflows/ci.yml/badge.svg)](https://github.com/ALH477/nixos-vm-gate/actions/workflows/ci.yml)

Boots the next NixOS generation in a throwaway VM and activates it only if it
came back clean.

## How it works

```
nix build (one evaluation, two installables)
  ├── system.build.toplevel   ─── pinned by a GC root ───┐
  └── system.build.vm                                    │
        │                                                │
        ├── boots headless as an unprivileged user       │
        ├── waits for systemd to settle                  │
        ├── re-runs activation against the live system   │
        ├── runs your health checks                      │
        └── writes a verdict over 9p ──── pass ──────────┤
                                                         ▼
                                        vm-gate-activate (root)
                                        nix-env --set + switch-to-configuration
```

Three properties are load-bearing:

**One evaluation.** Both the system closure and the VM come out of a single
`nix build`, so they are the same tree by construction. Activation then runs that
exact store path rather than calling `nixos-rebuild`, which would evaluate a
third time. With a mutable ref — `/etc/nixos`, `.`, a dirty git tree, a moving
`github:` ref — a re-evaluation five minutes later can produce something the VM
never saw.

**The closure is pinned.** `--out-link` plus named indirect roots hold the
validated paths for the life of the run, so a concurrent `nix-collect-garbage`
cannot delete what is about to be activated.

**Root does as little as possible.** Building and booting are unprivileged;
`vm-gate-activate` is the only root component, and it evaluates and fetches
nothing. See [SECURITY.md](SECURITY.md) — the gate is not a security boundary.

## Wiring it in

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  inputs.vm-gate.url = "github:ALH477/nixos-vm-gate";

  outputs = { self, nixpkgs, vm-gate }: {
    nixosConfigurations.workstation = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        vm-gate.nixosModules.default
        {
          demod.vmGate = {
            enable = true;
            flake = "/etc/nixos";
            hostName = "workstation";   # the flake attribute, not necessarily $HOSTNAME
            useBootLoader = true;

            checks = {
              audio = "systemctl is-active pipewire.service";
              tools = "test -x /run/current-system/sw/bin/faust";
            };

            extraVmConfig = { lib, ... }: {
              systemd.services.my-hardware-daemon.enable = false;
            };
          };
        }
      ];
    };
  };
}
```

```
nixos-rebuild-gated switch
nixos-rebuild-gated switch --flake .#workstation
nixos-rebuild-gated boot --gate-timeout 900 -- -L --builders ''
nixos-rebuild-gated test
nixos-rebuild-gated switch --no-gate       # escape hatch, logged loudly
```

The action is positional and must come first. Everything unrecognised goes to
`nix build`, not to activation — activation takes no arguments, because it runs
the path the VM validated and nothing else.

`build` and `dry-build` skip the gate; they never touch the running system.
`test` and `dry-activate` are gated but leave the system profile alone, so they
do not survive a reboot.

## Try it before trusting it

```
nix build github:ALH477/nixos-vm-gate#demo-vm
export VM_GATE_DIR=$(mktemp -d)
./result/bin/run-*-vm
cat "$VM_GATE_DIR/result"     # 0 = clean
```

## What it catches

- Evaluation and build failures.
- Units that fail to start in the candidate generation.
- Activation scripts that work at boot but break when re-run against a live
  system (`activation = "reactivate"`, the default).
- With `useBootLoader = true`, a generation that installs a bootloader which
  will not come back up. This is the failure mode most worth gating; it costs a
  scratch disk image and some seconds.
- Whatever your health checks assert.

## What it does not catch

**Hardware.** QEMU's VM variant replaces `fileSystems`, drops `swapDevices` and
disables LUKS. Disk layout, encryption, GPU, wireless, audio interfaces and
driver regressions are all outside the gate. Keep the previous generation in
your boot menu.

**The real transition, by default.** `switch` performs a live old-to-new unit
diff on a running system; that is where most "it broke on switch" failures live.
A cold boot passes straight through breakage a live transition trips on.
`activation = "reactivate"` closes part of this by re-running activation against
the live VM, but both sides are the same generation, so there is no unit diff.

`activation = "from-current"` rewinds the VM to the host's current generation and
switches forward, which does reproduce the diff. It is experimental: the old
generation references real disks, so its mount units fail inside the VM. The
rewind phase is therefore non-gating, and this mode generally needs
`extraVmConfig` tuning to be useful.

**Secrets.** sops-nix and agenix fail in the VM without the host key, which
surfaces as a degraded system and blocks every switch. Stub them in
`extraVmConfig` rather than setting `requireSystemRunning = false` — that flag is
the baseline check.

## Requirements

- nixpkgs with `virtualisation.vmVariant` and `virtualisation.diskImage = null`
  (23.11+); developed against 25.05.
- `/dev/kvm` reachable by the gate user, or expect a very slow gate.
- Disk in `stateDir` (`/var/lib/vm-gate`). Not `/tmp`, which is tmpfs here.
- Outside bootloader mode the guest root and writable store are tmpfs, charged
  against `memorySize`. The 4096 MiB default reflects that.

## Options

All under `demod.vmGate`:

| option | default | purpose |
| --- | --- | --- |
| `enable` | `false` | turn the gate on |
| `flake` / `hostName` | `/etc/nixos`, `networking.hostName` | what to build |
| `allowOverride` | `true` | permit `--flake` / `--host` at the CLI |
| `activation` | `reactivate` | `none`, `reactivate`, `from-current` |
| `useBootLoader` | `false` | boot through the real bootloader |
| `network` | `false` | give the gate VM outbound network |
| `timeout` | `600` | seconds before the VM is killed |
| `unitStartTimeout` / `checkTimeout` | `60` / `60` | per-unit and per-check limits |
| `memorySize` / `diskSize` / `cores` | `4096` / `8192` / `2` | VM resources |
| `requireSystemRunning` | `true` | degraded systemd fails the gate |
| `checks` / `checkPath` / `lintChecks` | `{}` / basics / `true` | health checks |
| `extraVmConfig` | `{}` | config applied only to the gate VM |
| `journal` | `on-failure` | when to keep the guest boot journal |
| `user` / `createUser` | `vm-gate` / `true` | unprivileged account for QEMU |
| `stateDir` / `logDir` / `keepRuns` | `/var/lib/vm-gate`, `/var/log/vm-gate`, `5` | scratch and diagnostics |
| `showDiff` | `true` | closure diff before gating |
| `installWrapper` / `package` | `true` / read-only | wrapper placement |

## Repository layout

```
flake.nix                        module + demo-vm outputs
modules/vm-gate.nix              the NixOS module
modules/nixos-rebuild-gated.sh   host driver: build, pin, boot, activate
modules/vm-gate-guest.sh         guest harness, writes the verdict
modules/vm-gate-activate.sh      the one root component
```

The three `.sh` files are `@token@` templates; `vm-gate.nix` substitutes store
paths and options into them at build time, so they are not directly executable
from a checkout.

## License

MIT. See [LICENSE](LICENSE).
