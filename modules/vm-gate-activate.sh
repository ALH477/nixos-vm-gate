# vm-gate-activate ACTION TOPLEVEL [INSTALL_BOOTLOADER]
#
# The entire privileged surface of vm-gate. It activates one already-built,
# already-validated store path. It does not evaluate, build, or fetch anything,
# so it cannot be steered by a flake, a lockfile or a network fetch.
#
# It is still root-equivalent: whoever can choose TOPLEVEL can choose what root
# runs. Do not put it in a NOPASSWD sudoers rule. See SECURITY.md.
set -euo pipefail
export PATH="@coreutils@:$PATH"

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
