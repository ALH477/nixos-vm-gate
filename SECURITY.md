# Trust model

**vm-gate is a correctness tool, not a security boundary.** It catches mistakes.
It does not contain adversaries.

The configuration under test writes its own verdict to the share the host reads.
A hostile configuration writes `0` and passes. If you do not already trust the
flake and every one of its inputs, the gate tells you nothing you did not already
assume.

What the design does provide is blast-radius reduction for the case where a
trusted input turns out to be compromised or simply broken.

## Privilege split

| Step | Runs as |
| --- | --- |
| Evaluate and build | the invoking user, or root |
| Boot the gate VM, run guest code | `demod.vmGate.user` (unprivileged, `kvm` group only) |
| Activate the validated closure | root, via `vm-gate-activate` |

QEMU never runs as root. It parses a guest-controlled disk image and maps a host
directory into the guest, so a qemu escape from a root-owned VM would land on
root directly. Running it as a dedicated system account means an escape lands on
an account whose only privilege is `/dev/kvm`.

The gate VM has no network by default (`virtualisation.restrictNetwork`). Turn it
on with `demod.vmGate.network = true` only when a health check needs it, and
understand that this gives every flake input outbound reachability from your
network position during the gate.

## Do not put this behind NOPASSWD sudo

`vm-gate-activate` takes an arbitrary store path and runs it as root. That is
root-equivalent by construction — the path's activation script is arbitrary code.
`nixos-rebuild-gated --flake` reaching any configuration makes this worse.

`demod.vmGate.allowOverride = false` pins the wrapper to one configuration, which
narrows what an unprivileged caller can select, but the flake reference still
points at a mutable tree that the caller may be able to write. Treat gated
rebuilds as an administrator action.

## What lands in the Nix store

Health check fragments are built into the store and are world-readable. Do not
inline credentials:

```nix
# wrong — readable by every user on the machine
checks.api = "curl -fsS -u admin:hunter2 http://localhost/health";

# right — read it at runtime, inside the VM
checks.api = ''
  curl -fsS -H "Authorization: Bearer $(cat /run/secrets/health-token)" \
    http://localhost/health >/dev/null
'';
```

## Diagnostics

A failed gate copies the guest's boot journal to `demod.vmGate.logDir`
(`/var/log/vm-gate`, mode 0700, root-owned) and prunes to the last
`keepRuns` failures. That journal is a complete boot log of the candidate
generation and may contain whatever your services log at startup. Set
`journal = "never"` if that is not acceptable on the host in question.

## Reporting

Security issues in this module: open a private advisory rather than an issue.
