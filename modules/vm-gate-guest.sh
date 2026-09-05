# vm-gate guest harness.
#
# Runs inside the gate VM in a transient systemd scope, so that activation
# phases which stop or restart units cannot take the harness down with them.
# Writes a verdict to the 9p share the host is watching, then powers off.
# Any path that fails to write that verdict is reported by the host as a
# failure: the gate fails closed.
set -u
export PATH="@path@"

share=/vmgate
status=0

log() { echo "vm-gate: $*"; }
fail() {
  echo "vm-gate: FAIL: $*"
  status=1
}

# Capture this before any activation phase: switch-to-configuration test
# repoints /run/current-system, so the candidate must be resolved up front.
candidate="$(readlink -f /run/current-system)"

if ! mountpoint -q "$share"; then
  log "FATAL: ${share} is not mounted, so no verdict can reach the host."
  log "The host will time out and treat this run as a failure."
  systemctl poweroff --no-block || true
  exit 1
fi

log "waiting for the boot transaction to settle"
if ! systemctl is-system-running --wait >"$share/system-state" 2>&1; then
  log "systemd reports: $(cat "$share/system-state" 2>/dev/null || echo unknown)"
  if [ "@requireRunning@" = "1" ]; then
    fail "system did not reach a running state"
  fi
fi

case "@activation@" in
  none) ;;

  reactivate)
    # Catches activation scripts and unit definitions that work during boot but
    # break when re-run against a live system. It cannot catch old -> new unit
    # diffs, because there is no diff here.
    log "re-running activation against the live system"
    if ! "$candidate/bin/switch-to-configuration" test; then
      fail "live re-activation failed"
    fi
    ;;

  from-current)
    old="$(cat "$share/old-system" 2>/dev/null || true)"
    if [ -n "$old" ] && [ -x "$old/bin/switch-to-configuration" ]; then
      # Rewind is scaffolding, not a result. The host's current generation
      # references real disks, so mount units are expected to fail here.
      log "rewinding to the host's current generation (best effort, not gating)"
      "$old/bin/switch-to-configuration" test ||
        log "rewind reported errors; continuing to the forward transition"
      log "switching forward to the candidate generation"
      if ! "$candidate/bin/switch-to-configuration" test; then
        fail "old -> new transition failed"
      fi
    else
      fail "activation=from-current, but no usable old system was passed in"
    fi
    ;;
esac

log "running health checks"
if ! @checkRunner@; then
  status=1
fi

systemctl list-units --state=failed --no-pager --plain >"$share/failed-units" 2>&1 || true

case "@journal@" in
  always)
    journalctl -b --no-pager >"$share/journal.log" 2>&1 || true
    ;;
  on-failure)
    if [ "$status" -ne 0 ]; then
      journalctl -b --no-pager >"$share/journal.log" 2>&1 || true
    fi
    ;;
  never) ;;
esac

printf '%s\n' "$status" >"$share/result"
sync
log "result=${status}"

# --no-block: a blocking poweroff from inside a scope systemd is about to tear
# down can deadlock against itself.
systemctl poweroff --no-block || true
exit "$status"
