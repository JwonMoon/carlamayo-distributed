#!/usr/bin/env bash
# Copy carla_data/ from the sim host to the inference host (for open-loop path 1).
#   deploy/scripts/sync-dataset-to-inference-host.sh [user@host] [remote_repo_dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source deploy/scripts/hosts-env.sh   # deploy/hosts.env -> INFERENCE_HOST, REMOTE_REPO
HOST="${1:-${INFERENCE_HOST:?set INFERENCE_HOST or deploy/hosts.env}}"
REMOTE_REPO="${2:-${REMOTE_REPO:-~/carlamayo}}"
DATA="${DATA_ROOT:-carla_data}"
rsync -avz --progress "$DATA/" "$HOST:$REMOTE_REPO/$DATA/"
echo "synced $DATA/ -> $HOST:$REMOTE_REPO/$DATA/"
