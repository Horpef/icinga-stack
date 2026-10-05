#!/bin/bash
# ---------------------------------------------------------------------------
# One-shot bootstrap for the Icinga Director module.
#
# The stock icinga/icingaweb2 entrypoint only configures Icinga Web itself
# (resources, authentication, enabled modules) - it knows nothing about the
# Director. On a brand new stack the `director` database is empty, so three
# manual steps would otherwise be needed after every `docker compose down -v`:
#
#   1. icingacli director migration run   -> create the Director schema
#   2. icingacli director kickstart run   -> import zones/endpoints/apiuser
#                                            and the 250+ check commands
#   3. icingacli director config deploy   -> push generated config to Icinga 2
#   4. icingacli director config deploymentstatus
#                                         -> record that Icinga 2 ACTUALLY
#                                            started it (otherwise the stack
#                                            stays at "still pending")
#
# This script performs exactly those steps and is idempotent: on an already
# configured stack every command reports "nothing to do" and finishes fast.
#
# Run by the `director-init` service in docker-compose.yml, which bind mounts
# this file and shares the `icinga_web_data` volume with the `icinga-web`
# service (so /etc/icingaweb2 -> /data/etc/icingaweb2 already contains the
# config written by the icinga-web entrypoint, which ran first).
#
# Exit codes on Icinga Director 1.11.9:
#   director migration run      0 = applied, or nothing pending
#   director migration pending  0 = pending, 1 = none pending
#   director kickstart required 0 = kickstart needed, 1 = already kickstarted
#   director config deploy      0 = deployed, or config already matches
#   director config deploymentstatus  0 = JSON report (also triggers the
#                                         collection of startup_succeeded)
# ---------------------------------------------------------------------------
set -uo pipefail

TAG="[director-init]"
SLEEP=5
# 40 minutes ceiling: a fresh kickstart imports 254 commands and takes ~10 min.
MAX=480

log() { echo "$TAG $*"; }

# Retrying can never fix these - fail loudly instead of spinning for 40 min.
# Everything else (DB/API not up yet, half-open connections, curl errors,
# "ERROR:" lines from the CLI) is treated as transient.
is_fatal() {
  grep -qiE 'SQLSTATE\[42S01\]|already exists|access denied|SQLSTATE\[1045\]' <<<"$1"
}

# Set by callers of retry(): a regex that, when the command's output matches
# it, is an *expected* answer even though the exit code may be non-zero.
# Example: `director kickstart required` exits 1 with
# "Kickstart configured, execution is not required" when there is nothing to do.
OK_PATTERN=""

# Run a command until it stops complaining. Prints output, returns its code.
retry() { # <label> <max tries> <cmd...>
  local label="$1" max="$2" out rc i
  shift 2
  for ((i = 1; i <= max; i++)); do
    out=$("$@" 2>&1); rc=$?

    # Non-zero exit code but the CLI is explicitly telling us "all good".
    if [[ -n $OK_PATTERN ]] && grep -qE "$OK_PATTERN" <<<"$out"; then
      printf '%s\n' "$out"
      return 0
    fi
    if [[ $rc -eq 0 && -z $out ]]; then
      printf '%s\n' "$out"; return 0          # silent success
    fi
    if is_fatal "$out"; then
      log "FATAL in $label: $(head -n1 <<<"$out")"
      return 1
    fi
    if [[ $rc -ne 0 ]] || grep -qiE 'error|failed|can.t connect|refused|no such host' <<<"$out"; then
      [[ $i -eq 1 || $((i % 12)) -eq 0 ]] &&
        log "$label waiting (attempt $i/$max): $(head -n1 <<<"$out")"
      sleep "$SLEEP"
      continue
    fi
    printf '%s\n' "$out"
    return "$rc"
  done
  log "FATAL: $label not ready after $((max * SLEEP))s"
  return 1
}

log "starting Director bootstrap"

# --- 1. schema migration ---------------------------------------------------
log "step 1/4: director database migration"
OUT=$(retry "migration" "$MAX" icingacli director migration run) || {
  log "migration failed"; exit 1; }
log "schema is up to date (120 tables on a fresh install)"

# --- 2. kickstart ----------------------------------------------------------
log "step 2/4: kickstart (zones, endpoints, apiuser, commands)"
# `kickstart required` exits 1 when there is nothing to do - tell retry().
OK_PATTERN='execution is not required'
OUT=$(retry "kickstart check" "$MAX" icingacli director kickstart required) || {
  log "cannot query kickstart status: $(head -n3 <<<"$OUT")"; exit 1; }
OK_PATTERN=""
if grep -q 'execution is not required' <<<"$OUT"; then
  log "kickstart already done, skipping"
else
  log "running kickstart - imports 254 commands, takes ~10 minutes"
  OUT=$(retry "kickstart run" "$MAX" icingacli director kickstart run) || {
    log "kickstart failed: $(head -n3 <<<"$OUT")"; exit 1; }
  log "kickstart finished"
fi

# --- 3. deploy -------------------------------------------------------------
# `config deploy` is used WITHOUT --wait on purpose: --wait polls for an Icinga
# 2 restart and gives up ("deployment timed out") even when the push worked.
# The daemon reloads on its own (log: "Got reload command").
log "step 3/4: deploy generated configuration to Icinga 2"
OUT=$(retry "deploy" "$MAX" icingacli director config deploy) || {
  log "deploy failed: $(head -n3 <<<"$OUT")"; exit 1; }
log "$(head -n1 <<<"$OUT")"

# --- 4. confirm that Icinga 2 started it ------------------------------------
# Pushing the config does NOT record whether Icinga 2 accepted it. The
# director_deployment_log row keeps `stage_collected`/`startup_succeeded` at
# NULL until something calls ConditionalDeployment::refresh() or
# DeploymentStatus::getDeploymentStatus(), which is only done by:
#   * a SECOND `icingacli director config deploy` (the "Config matches last
#     deployed one" case), `icingacli director config deploymentstatus`, the
#     deployments page of the web UI, or
#   * the Director daemon (Daemon/DeploymentChecker).
# A one-shot bootstrap that deploys exactly once therefore leaves the stack at
# "[WARNING] The last Deployment started ... and is still pending" for a whole
# hour (the point at which LegacyDeploymentApi::wipeInactiveStages() gives up).
# `deploymentstatus` is the cheap, purpose built way to trigger it.
log "step 4/4: confirm that Icinga 2 started the deployed configuration"
confirmed=0
for ((i = 1; i <= 60; i++)); do
  # Collects status/startup.log of the stage; needs Icinga 2 to have written
  # them first, hence the loop (~2 s after a reload in practice).
  icingacli director config deploymentstatus >/dev/null 2>&1 || true
  # Capture before grepping: the script runs with `set -o pipefail`, so
  # `icingacli ... | grep` would inherit a non-zero exit code from the CLI.
  H=$(icingacli director health 2>&1 || true)
  if grep -q 'last Deployment was successful' <<<"$H"; then
    confirmed=1
    break
  fi
  if [[ $i -eq 1 || $((i % 6)) -eq 0 ]]; then
    log "waiting for Icinga 2 to activate the stage (attempt $i/60): $(grep -m1 -E 'last Deployment' <<<"$H" || echo 'n/a')"
  fi
  sleep 5
done
if [[ $confirmed -ne 1 ]]; then
  log "FATAL: Icinga 2 never confirmed the deployment (config error?)"
  exit 1
fi
log "Icinga 2 confirmed the deployment"

log "Director bootstrap complete"
exit 0
