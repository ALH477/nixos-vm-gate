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

## Prior art

The pieces this composes all exist separately. What was missing is the wiring.

**`nixos-rebuild build-vm` / `build-vm-with-bootloader`** do the VM boot, and
`dry-activate` and `test` cover part of the rest. They are the primitives this
automates. Run by hand, nothing connects the VM's outcome to the activation
decision, and each invocation evaluates again — so the tree you tested and the
tree you switch to are only probably the same.

**`system.preSwitchChecks`** (nixpkgs, in 25.05) is the closest thing in the
tree: an attrset of shell fragments run by `switch-to-configuration` before it
commits, where any failure aborts the switch. Same shape as `checks` here, and
also shellchecked via `writeShellApplication`. It runs on the live host, so it
asserts preconditions; it cannot answer whether the new generation comes up.
The two compose — use `preSwitchChecks` for "is this host in a fit state to
switch", and the gate for "does the thing I am about to switch to work".

**Post-activation rollback** — [deploy-rs](https://github.com/serokell/deploy-rs)
magic rollback, which drops a canary the deployer must clear before a timeout,
and the various dead-man-switch wrappers — takes the opposite approach: activate,
then undo if it goes wrong. That covers what a cold VM boot structurally cannot,
namely the live old-to-new unit diff (see *What it does not catch*). Complementary,
not competing. The difference in risk posture is that a rollback tool does
activate the bad generation first.

**Boot counting** (`boot.loader.systemd-boot.bootCounting`, currently
nixos-unstable only — not in 25.05 or 25.11) is the firmware-level backstop for
the same failure mode `useBootLoader = true` targets: systemd-boot decrements a
per-entry counter and `systemd-bless-boot` marks an entry good once the boot
succeeds. Worth enabling alongside this once it reaches your channel; it catches
what the gate missed.

**NixOS VM tests** (`runNixOSTest`) are a far more capable assertion framework —
multi-node, a Python driver, and they run under `nix flake check` in CI. They
test a purpose-built configuration, though, and aiming one at your real
`nixosConfigurations.<host>` is known to be awkward. This gate inverts that: weak
assertions against the exact closure you are about to activate.

**Fleet deployment tooling** — [morph](https://github.com/DBCDK/morph)
(`deployment.healthChecks`, command and HTTP, repeated until success),
[colmena](https://github.com/nix-community/colmena),
[nixos-healthchecks](https://github.com/mrVanDalo/nixos-healthchecks) — runs
checks after deploying to remote hosts. This is local and runs before activation.

What is left over, and what this is actually for: one evaluation shared between
the VM and the activation target, a closure pinned against the collector across
the gate window, and a verdict that gates rather than reverts.

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
