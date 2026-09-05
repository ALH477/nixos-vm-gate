# Trust model

**vm-gate is a correctness tool, not a security boundary.** It catches mistakes.
It does not contain adversaries.

The configuration under test writes its own verdict to the share the host reads.
A hostile configuration writes `0` and passes. If you do not already trust the
flake and every one of its inputs, the gate tells you nothing you did not already
assume.

What the design does provide is blast-radius reduction for the case where a
trusted input turns out to be compromised or simply broken.

The host does cross-check the verdict against the rest of what the harness
should have produced: `system-state` and `failed-units` must both be present,
and a passing verdict that claims success while systemd reports anything other
than `running` is rejected. That closes the accidental passes — an early
poweroff, a truncated share, a unit that writes a `0` before the checks run —
and raises the cost of a deliberate one from writing one file to writing a
consistent set. It does not close the deliberate case, and no in-guest check
can: the guest is the thing under test.

## Privilege split

| Step | Runs as |
| --- | --- |
| Evaluate and build | the invoking user, or root |
| Boot the gate VM, run guest code | `demod.vmGate.user` (unprivileged, `kvm` group only) |
| Activate the validated closure | root, via `vm-gate-activate` |

QEMU never runs as root, and this matters more than the usual escape argument.

The VM runner exports three host directories over 9p with
`security_model=none`, which is passthrough: the 9p server creates files using
the credentials the guest asks for, with the process's own privileges. Those
exports are the host's `/nix/store`, and `$TMPDIR/xchg` and `$SHARED_DIR` for
the guest's scratch space. With qemu running as root, a guest would not need an
escape at all — ordinary 9p writes would let it plant a setuid-root binary in
the shared directory, or add paths to the host's store. Running as an
unprivileged account reduces that to files owned by an account whose only
privilege is `/dev/kvm`.

The verdict share at `/vmgate` is the exception: it uses the `mapped-xattr`
default, so guest-requested ownership and mode are stored as host xattrs rather
than applied. The guest cannot use it to create a host file it does not already
have the rights to create.

The gate user therefore must not have privileges that make those exports
writable in an interesting way. The module warns if it is in the `nixbld` group
(`/nix/store` is group-writable by `nixbld`, and the sticky bit stops replacing
existing paths, not adding new ones) or if it is a Nix trusted user, which is
root-equivalent through the daemon. The default `createUser = true` account has
neither.

The gate process is additionally launched under `setpriv --no-new-privs`, so an
escaped process cannot regain privilege through any setuid binary it reaches.

Only the verdict share and a scratch directory are handed to the gate user. The
workspace root stays root-owned and merely traversable, so a guest that does get
out of qemu cannot unlink the GC roots pinning the closure about to be
activated, nor rewrite the console log that records its own run.

**Running the wrapper as an unprivileged user gets no privilege split at all.**
In that path qemu runs as the invoking user — who, by construction, can `sudo`
to activate. The split exists only when the wrapper itself runs as root.

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

## Concurrency

Two gated rebuilds reaching activation together would race `nix-env --set` on
the system profile. The lock that prevents this is taken by `vm-gate-activate`
as root, on `/run/lock/vm-gate-activate.lock`, and is held across
`switch-to-configuration` — not by the wrapper. An unprivileged caller cannot
write a machine-global lock path, so a wrapper-side lock would be per-user at
best and would silently permit the race it appears to prevent.

The wrapper still takes a best-effort lock so a second run fails fast instead of
burning a VM boot it cannot use. Treat that one as a convenience.

## Diagnostics

A failed gate copies the guest's boot journal to `demod.vmGate.logDir`
(`/var/log/vm-gate`, mode 0700, root-owned) and prunes to the last
`keepRuns` failures. That journal is a complete boot log of the candidate
generation and may contain whatever your services log at startup. Set
`journal = "never"` if that is not acceptable on the host in question.

## Reporting

Security issues in this module: open a private advisory rather than an issue.
