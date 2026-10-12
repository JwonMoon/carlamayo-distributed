#!/usr/bin/env bash
# Copy the inference host's profile CSVs for one run into the local run folder.
#
#   tools/fetch_server_profile.sh <run_id> [user@host] [remote_repo_dir]
#
# Run on the sim host after a closed/live-open/open-loop run. The host comes from
# deploy/hosts.env (INFERENCE_HOST_IP, INFERENCE_SSH_USER, REMOTE_REPO); override with
# arguments or environment variables INFERENCE_HOST=user@ip REMOTE_REPO=~/carlamayo RUNS_ROOT=runs
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source deploy/scripts/hosts-env.sh   # deploy/hosts.env -> INFERENCE_HOST, REMOTE_REPO
RUN_ID="${1:?usage: $0 <run_id> [user@host] [remote_repo_dir]}"
HOST="${2:-${INFERENCE_HOST:?set INFERENCE_HOST or deploy/hosts.env}}"
REMOTE_REPO="${3:-${REMOTE_REPO:-~/carlamayo}}"
RUNS_ROOT="${RUNS_ROOT:-runs}"
mkdir -p "$RUNS_ROOT/$RUN_ID"
rsync -avz --progress \
  "$HOST:$REMOTE_REPO/$RUNS_ROOT/$RUN_ID/" \
  --include='profile_server*.csv' --include='server_info.json' --exclude='*' \
  "$RUNS_ROOT/$RUN_ID/"
echo "Fetched server profile into $RUNS_ROOT/$RUN_ID/"
ls -la "$RUNS_ROOT/$RUN_ID/" | grep -E 'profile_server|server_info' || true
