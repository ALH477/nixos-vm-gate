# vm-gate-activate ACTION TOPLEVEL [INSTALL_BOOTLOADER]
#
# The entire privileged surface of vm-gate. It activates one already-built,
# already-validated store path. It does not evaluate, build, or fetch anything,
# so it cannot be steered by a flake, a lockfile or a network fetch.
#
# It is still root-equivalent: whoever can choose TOPLEVEL can choose what root
# runs. Do not put it in a NOPASSWD sudoers rule. See SECURITY.md.
set -euo pipefail
export PATH="@coreutils@:@utilLinux@:$PATH"

die() { echo "vm-gate-activate: $*" >&2; exit 1; }

action="${1:-}"
toplevel="${2:-}"
install_bootloader="${3:-0}"

[[ $EUID -eq 0 ]] || die "must run as root"

case "$action" in
  switch | boot | test | dry-activate) ;;
  *) die "unsupported action '${action}'" ;;
esac

[[ $toplevel == /nix/store/* ]] || die "refusing to activate '${toplevel}': not a store path"
[[ $toplevel != *..* ]] || die "refusing to activate '${toplevel}': path traversal"
@nixStore@ --check-validity "$toplevel" >/dev/null 2>&1 ||
  die "'${toplevel}' is not a valid store path"
[[ -x $toplevel/bin/switch-to-configuration ]] ||
  die "'${toplevel}' has no switch-to-configuration (system.switch.enable = false?)"

# Serialise the profile update. This lock lives here rather than in the wrapper
# because this is the only component guaranteed to be root, and /nix/var/nix is
# the resource actually being raced for. A wrapper-side lock cannot cover it:
# unprivileged callers cannot write a machine-global lock path, so two
# concurrent gated rebuilds would each take a private lock and both proceed.
lock=/run/lock/vm-gate-activate.lock
if ! exec 9>"$lock"; then
  die "cannot open ${lock}"
fi
flock -w 900 9 || die "another activation has held ${lock} for 15 minutes; refusing to race"

# `test` and `dry-activate` deliberately leave the system profile alone, which
# is what makes them survivable across a reboot. Only switch/boot commit.
case "$action" in
  switch | boot)
    @nixEnv@ --profile /nix/var/nix/profiles/system --set "$toplevel"
    ;;
esac

if [[ $install_bootloader == 1 ]]; then
  export NIXOS_INSTALL_BOOTLOADER=1
fi

exec "$toplevel/bin/switch-to-configuration" "$action"
