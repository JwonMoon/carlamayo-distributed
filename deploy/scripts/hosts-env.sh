#!/usr/bin/env bash
# Shared: load deploy/hosts.env (if present) and expose INFERENCE_TARGET / INFERENCE_SSH.
# Environment variables already set take precedence over the file.
#   source "$(dirname "$0")/hosts-env.sh"
_HOSTS_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$_HOSTS_ENV_DIR/hosts.env" ]; then
  while IFS='=' read -r key value; do
    case "$key" in ''|\#*) continue ;; esac
    key="$(echo "$key" | tr -d '[:space:]')"
    value="${value%%#*}"; value="$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -z "${!key:-}" ]; then export "$key=$value"; fi
  done < "$_HOSTS_ENV_DIR/hosts.env"
fi
export SIM_HOST_IP="${SIM_HOST_IP:-}"
export INFERENCE_HOST_IP="${INFERENCE_HOST_IP:-}"
export INFERENCE_PORT="${INFERENCE_PORT:-50051}"
export INFERENCE_SSH_USER="${INFERENCE_SSH_USER:-ubuntu}"
export REMOTE_REPO="${REMOTE_REPO:-~/carlamayo}"
if [ -n "$INFERENCE_HOST_IP" ]; then
  export INFERENCE_TARGET="${INFERENCE_TARGET:-$INFERENCE_HOST_IP:$INFERENCE_PORT}"
  export INFERENCE_HOST="${INFERENCE_HOST:-$INFERENCE_SSH_USER@$INFERENCE_HOST_IP}"
fi
