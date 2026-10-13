#!/usr/bin/env bash
# One-time setup for the CARLA sim host (A): CARLA 0.9.16 + torch-free Python env.
set -euo pipefail
REPO="${REPO:-$HOME/carlamayo}"
CARLA_DIR="${CARLA_ROOT:-$HOME/carla}"

command -v nvidia-smi >/dev/null 2>&1 || echo "WARN: nvidia-smi not found; install the NVIDIA driver first (docs/distributed/porting-guide.md section 2.5)"
sudo apt-get update
sudo apt-get install -y python3 python3-venv ffmpeg libvulkan1 rsync netcat-openbsd

# Pick an interpreter: 3.10 if present (Ubuntu 22.04 / Deep Learning AMI), else the system python3
# (3.12 on Ubuntu 24.04). The carla 0.9.16 wheel on PyPI covers 3.10-3.12.
PY="$(command -v python3.10 || command -v python3.12 || command -v python3.11 || command -v python3)"
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
  || { echo "ERROR: $PY is older than 3.10; install python3.10+ first"; exit 1; }
"$PY" -m venv --help >/dev/null 2>&1 || sudo apt-get install -y "$(basename "$PY")-venv"

if [ ! -f "$CARLA_DIR/CarlaUE4.sh" ]; then
  mkdir -p "$CARLA_DIR" && cd "$CARLA_DIR"
  wget -q --show-progress https://tiny.carla.org/carla-0-9-16-linux -O carla-0.9.16.tar.gz
  tar -xzf carla-0.9.16.tar.gz && rm carla-0.9.16.tar.gz
fi
grep -q "CARLA_ROOT" "$HOME/.bashrc" || echo "export CARLA_ROOT=$CARLA_DIR" >> "$HOME/.bashrc"

cd "$REPO"
"$PY" -m venv venv-sim
# shellcheck disable=SC1091
source venv-sim/bin/activate
pip install --upgrade pip
pip install -r requirements-sim.txt || {
  echo "carla wheel not on PyPI for this Python? try:"
  echo "  pip install $CARLA_DIR/PythonAPI/carla/dist/carla-0.9.16-*.whl"
}
echo "sim host ready ($(python --version)): source $REPO/venv-sim/bin/activate; export CARLA_ROOT=$CARLA_DIR"
