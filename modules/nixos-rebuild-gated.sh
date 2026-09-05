# nixos-rebuild-gated ACTION [options] [-- nix build args]
#
# Evaluates the target configuration exactly once, pins the resulting closure
# against the garbage collector, boots it in an unprivileged throwaway VM, and
# activates that same pinned store path only if the VM came back clean.
#
# It deliberately does not call nixos-rebuild: a second evaluation could pick up
# a different tree than the one that was tested.
set -euo pipefail
export PATH="@coreutils@:@utilLinux@:$PATH"

NIX="@nix@"
NIX_STORE="@nixStore@"
JQ="@jq@"
ENV_BIN="@env@"
ACTIVATE="@activate@"

flake="@flake@"
host="@host@"
gate_timeout="@timeout@"
use_bootloader="@useBootLoader@"
vm_attr="@vmAttr@"
gate_user="@gateUser@"
log_dir="@logDir@"
state_dir="@stateDir@"
keep_runs="@keepRuns@"
allow_override="@allowOverride@"
show_diff="@showDiff@"

skip_gate=0
install_bootloader=0
nix_args=()
work=""
share=""
vm_pid=""
keep_logs=0

usage() {
  cat <<EOF
Usage: nixos-rebuild-gated <switch|boot|test|dry-activate|build> [options] [-- nix build args]

  --flake REF[#HOST]    configuration to build (default: ${flake})
  --host NAME           attribute under nixosConfigurations (default: ${host})
  --gate-timeout SEC    wall-clock limit for the gate VM (default: ${gate_timeout})
  --install-bootloader  reinstall the bootloader during activation
  --no-diff             skip the closure diff against the running system
  --no-gate             skip the VM entirely (recorded loudly; think first)

Unrecognised arguments, and everything after --, are passed to 'nix build'.
Activation takes no pass-through arguments: it runs the exact store path the
VM validated.

build and dry-activate never touch the running system, so they skip the gate.
EOF
}

die() {
  echo "vm-gate: $*" >&2
  exit 1
}

log() { echo "vm-gate: $*"; }

# --- argument handling ------------------------------------------------------
# The action is positional. Earlier revisions scanned every argument for action
# keywords, which silently turned '--profile-name test' into the 'test' action.

action="${1:-}"
case "$action" in
  -h | --help)
    usage
    exit 0
    ;;
  switch | boot | test | dry-activate | build | dry-build) shift ;;
  "") die "no action given; try --help" ;;
  *) die "unknown action '${action}'; try --help" ;;
esac

override_guard() {
  if [[ $allow_override != 1 ]]; then
    die "$1 is disabled on this host (demod.vmGate.allowOverride = false)"
  fi
}

while (($#)); do
  case "$1" in
    --flake)
      [[ $# -ge 2 ]] || die "--flake needs a value"
      override_guard --flake
      flake="$2"
      shift 2
      ;;
    --host)
      [[ $# -ge 2 ]] || die "--host needs a value"
      override_guard --host
      host="$2"
      shift 2
      ;;
    --gate-timeout)
      [[ $# -ge 2 ]] || die "--gate-timeout needs a value"
      gate_timeout="$2"
      shift 2
      ;;
    --install-bootloader)
      install_bootloader=1
      shift
      ;;
    --no-diff)
      show_diff=0
      shift
      ;;
    --no-gate)
      skip_gate=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      nix_args+=("$@")
      break
      ;;
    *)
      nix_args+=("$1")
      shift
      ;;
  esac
done

[[ $gate_timeout =~ ^[0-9]+$ ]] || die "--gate-timeout must be a whole number of seconds"
[[ $gate_timeout -ge 30 ]] || die "--gate-timeout below 30s will not let any VM finish booting"

if [[ $flake == *"#"* ]]; then
  host="${flake#*#}"
  flake="${flake%%#*}"
fi
[[ -n $host ]] || die "no configuration name; pass --host or set demod.vmGate.hostName"

attr_prefix="${flake}#nixosConfigurations.\"${host}\".config.system.build"

# --- workspace --------------------------------------------------------------
# Not /tmp: that is tmpfs on NixOS, so a bootloader-mode disk image would be
# charged against host RAM.

pick_workspace() {
  if ((EUID == 0)); then
    mkdir -p "$state_dir"
    chmod 0750 "$state_dir"
    mktemp -d "${state_dir}/run.XXXXXXXX"
  else
    local base="${TMPDIR:-/var/tmp}"
    [[ -d $base && -w $base ]] || base=/var/tmp
    mktemp -d "${base}/vm-gate.XXXXXXXX"
  fi
}

pick_log_dir() {
  if ((EUID == 0)) && mkdir -p "$log_dir" 2>/dev/null; then
    chmod 0700 "$log_dir"
    printf '%s\n' "$log_dir"
    return 0
  fi
  local fallback="${XDG_STATE_HOME:-${HOME:-/var/tmp}/.local/state}/vm-gate"
  mkdir -p "$fallback" 2>/dev/null || return 1
  chmod 0700 "$fallback" 2>/dev/null || true
  printf '%s\n' "$fallback"
}

kill_vm() {
  [[ -n $vm_pid ]] || return 0
  kill -0 "$vm_pid" 2>/dev/null || return 0
  # Negative pid targets the process group, so a runner script that forks qemu
  # instead of exec'ing it cannot leave an orphan holding the share open.
  kill -TERM -"$vm_pid" 2>/dev/null || kill -TERM "$vm_pid" 2>/dev/null || true
  local _i
  for _i in $(seq 1 20); do
    kill -0 "$vm_pid" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -KILL -"$vm_pid" 2>/dev/null || kill -KILL "$vm_pid" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  kill_vm
  exec 9>&- 2>/dev/null || true
  if [[ -n $work && -d $work ]]; then
    if ((keep_logs)) && ! save_artifacts; then
      # Nowhere durable to put them, so keep the workspace rather than
      # discarding the only record of the failure.
      echo "vm-gate: diagnostics left in ${work}" >&2
      return $rc
    fi
    rm -rf "$work"
  fi
  return $rc
}

save_artifacts() {
  local dest base
  base="$(pick_log_dir)" || return 1
  dest="${base}/$(date -u +%Y%m%dT%H%M%SZ)-${host}"
  mkdir -p "$dest" && chmod 0700 "$dest" || return 0
  cp -a "$work/console.log" "$dest/" 2>/dev/null || true
  [[ -d $share ]] && cp -a "$share/." "$dest/" 2>/dev/null || true
  # The guest journal is a full boot log of the candidate generation. Keep it
  # readable only by the operator, and only for the last few failures.
  chown -R 0:0 "$dest" 2>/dev/null || true
  chmod -R go-rwx "$dest" 2>/dev/null || true
  echo "vm-gate: diagnostics saved to ${dest}" >&2
  prune_artifacts "$base"
}

prune_artifacts() {
  local base="$1" old
  local -a dirs=()
  while IFS= read -r old; do
    [[ -n $old ]] && dirs+=("$old")
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | cut -d' ' -f2-)
  if ((${#dirs[@]} > keep_runs)); then
    rm -rf -- "${dirs[@]:keep_runs}"
  fi
}

activate() {
  local -a cmd=("$ACTIVATE" "$action" "$toplevel" "$install_bootloader")
  if ((EUID == 0)); then
    "${cmd[@]}"
  else
    log "escalating for activation only"
    sudo "${cmd[@]}"
  fi
}

# --- fast paths -------------------------------------------------------------

case "$action" in
  build | dry-build) skip_gate=1 ;;
esac

trap cleanup EXIT INT TERM

work="$(pick_workspace)"
chmod 0700 "$work"
share="$work/share"
mkdir -p "$share"

# One lock for the whole gate-then-activate sequence: two concurrent runs would
# race on the system profile.
lock_file="${work}/lock"
if [[ -d /run/lock && -w /run/lock ]]; then
  lock_file=/run/lock/vm-gate.lock
fi
exec 8>"$lock_file"
flock -n 8 || die "another gated rebuild is already running"

# --- single evaluation ------------------------------------------------------
# Both installables come from one 'nix build' invocation, so they are guaranteed
# to be the same evaluation of the same tree. --out-link registers GC roots as
# part of the build, closing the window where a concurrent collection could
# delete the closure between validation and activation.

log "evaluating and building ${flake}#${host}"
if ! "$NIX" build \
  --extra-experimental-features "nix-command flakes" \
  --json --out-link "$work/nix-out" \
  "${nix_args[@]}" \
  "${attr_prefix}.toplevel" "${attr_prefix}.${vm_attr}" >"$work/build.json"; then
  echo "vm-gate: build failed for configuration '${host}'." >&2
  if names="$("$NIX" eval --extra-experimental-features "nix-command flakes" \
    --json "${flake}#nixosConfigurations" --apply builtins.attrNames 2>/dev/null)"; then
    echo "vm-gate: configurations available in ${flake}: ${names}" >&2
  fi
  exit 1
fi

toplevel=""
vm=""
while IFS= read -r path; do
  [[ -n $path ]] || continue
  # Identify by content rather than by position: the order of --json results is
  # not something worth betting an activation on.
  if compgen -G "${path}/bin/run-*-vm" >/dev/null; then
    vm="$path"
  elif [[ -e "${path}/init" ]]; then
    toplevel="$path"
  fi
done < <("$JQ" -r '.[].outputs | to_entries[] | .value' "$work/build.json")

[[ -n $toplevel ]] || die "could not identify the system closure in the build output"
[[ -n $vm ]] || die "could not identify the gate VM in the build output"

# Named, order-independent GC roots that live exactly as long as this run.
"$NIX_STORE" --realise --add-root "$work/root-system" "$toplevel" >/dev/null
"$NIX_STORE" --realise --add-root "$work/root-vm" "$vm" >/dev/null

log "candidate system: ${toplevel}"

if ((show_diff)) && [[ -e /run/current-system ]]; then
  "$NIX" store diff-closures --extra-experimental-features "nix-command flakes" \
    /run/current-system "$toplevel" || true
fi

if ((skip_gate)); then
  case "$action" in
    build | dry-build)
      log "built; not activating"
      exit 0
      ;;
  esac
  log "WARNING: --no-gate, activating an untested generation"
  activate
  exit $?
fi

# --- gate VM ----------------------------------------------------------------

runner="$(echo "$vm"/bin/run-*-vm)"
[[ -x $runner ]] || die "no VM runner found under ${vm}"

readlink -f /run/current-system >"$share/old-system" 2>/dev/null || true

vm_env=("VM_GATE_DIR=${share}" "TMPDIR=${work}" "HOME=${work}")
if [[ $use_bootloader == 1 ]]; then
  vm_env+=("NIX_DISK_IMAGE=${work}/gate.qcow2")
fi

vm_cmd=()
if ((EUID == 0)); then
  # Never run qemu as root: it is parsing a guest-controlled disk and mapping a
  # host directory into it. Root keeps only the activation step.
  id -u "$gate_user" >/dev/null 2>&1 ||
    die "gate user '${gate_user}' does not exist; set demod.vmGate.createUser = true"
  chown -R "$gate_user" "$work"
  vm_cmd=("@runuser@" -u "$gate_user" -- "$ENV_BIN" "${vm_env[@]}" "$runner")
  if ! runuser -u "$gate_user" -- test -w /dev/kvm 2>/dev/null; then
    log "WARNING: ${gate_user} cannot write /dev/kvm; the gate VM will be emulated and slow"
  fi
else
  vm_cmd=("$ENV_BIN" "${vm_env[@]}" "$runner")
  [[ -w /dev/kvm ]] ||
    log "WARNING: /dev/kvm is not writable by $(id -un); the gate VM will be emulated and slow"
fi

# A read-write FIFO for the guest's stdin. With -nographic, qemu muxes the
# monitor onto stdio and can exit immediately on EOF, which </dev/null delivers.
mkfifo -m 600 "$work/stdin"
exec 9<>"$work/stdin"

log "booting the gate VM (timeout ${gate_timeout}s)"
set -m
"${vm_cmd[@]}" <&9 >"$work/console.log" 2>&1 &
vm_pid=$!
set +m

timed_out=0
deadline=$((SECONDS + gate_timeout))
while kill -0 "$vm_pid" 2>/dev/null; do
  if ((SECONDS >= deadline)); then
    timed_out=1
    log "timeout reached; terminating the gate VM"
    kill_vm
    break
  fi
  sleep 1
done

qemu_rc=0
wait "$vm_pid" 2>/dev/null || qemu_rc=$?
vm_pid=""

# --- verdict ----------------------------------------------------------------

if [[ ! -r "$share/result" ]]; then
  keep_logs=1
  echo "vm-gate: the VM produced no verdict (qemu exit ${qemu_rc})." >&2
  if ((timed_out)); then
    echo "vm-gate: it hit the ${gate_timeout}s timeout. Either it hung, or" >&2
    echo "vm-gate: demod.vmGate.enable is not set in the configuration under test." >&2
  fi
  echo "vm-gate: last 40 lines of console:" >&2
  tail -n 40 "$work/console.log" >&2 || true
  exit 1
fi

result="$(tr -d '[:space:]' <"$share/result")"
if [[ ! $result =~ ^[0-9]+$ ]]; then
  keep_logs=1
  die "the VM wrote a malformed verdict; treating as failure"
fi

if ((result != 0)); then
  keep_logs=1
  echo "vm-gate: health checks failed inside the VM; not activating." >&2
  if [[ -s "$share/failed-units" ]]; then
    echo "vm-gate: failed units:" >&2
    cat "$share/failed-units" >&2
  fi
  echo "vm-gate: last 40 lines of console:" >&2
  tail -n 40 "$work/console.log" >&2 || true
  exit 1
fi

log "gate passed; activating ${toplevel}"
if ! activate; then
  rc=$?
  keep_logs=1
  echo "vm-gate: activation failed after a passing gate." >&2
  case "$action" in
    switch | boot)
      echo "vm-gate: the system profile has already been updated. To go back:" >&2
      echo "vm-gate:   nix-env -p /nix/var/nix/profiles/system --rollback" >&2
      echo "vm-gate:   /nix/var/nix/profiles/system/bin/switch-to-configuration switch" >&2
      ;;
  esac
  exit $rc
fi

log "done"
