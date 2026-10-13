#!/usr/bin/env bash
# One-time setup for the CARLA sim host (A): CARLA 0.9.16 + torch-free Python env.
# Works on any Ubuntu release: the venv uses a uv-managed Python 3.12 (the carla 0.9.16
# wheel on PyPI exists for 3.10-3.12 only; Ubuntu 26.04 ships 3.14).
set -euo pipefail
REPO="${REPO:-$HOME/carlamayo}"
CARLA_DIR="${CARLA_ROOT:-$HOME/carla}"
CARLA_URL="${CARLA_URL:-https://tiny.carla.org/carla-0-9-16-linux}"

command -v nvidia-smi >/dev/null 2>&1 || echo "WARN: nvidia-smi not found; install the NVIDIA driver first (docs/distributed/porting-guide.md section 2.5)"
sudo apt-get update
sudo apt-get install -y curl wget ffmpeg libvulkan1 rsync netcat-openbsd

if [ ! -f "$CARLA_DIR/CarlaUE4.sh" ]; then
  mkdir -p "$CARLA_DIR" && cd "$CARLA_DIR"
  if [ ! -s carla-0.9.16.tar.gz ]; then
    rm -f carla-0.9.16.tar.gz
    if ! wget "$CARLA_URL" -O carla-0.9.16.tar.gz || [ "$(stat -c %s carla-0.9.16.tar.gz)" -lt 1000000 ]; then
      rm -f carla-0.9.16.tar.gz
      echo "ERROR: CARLA download failed ($CARLA_URL)."
      echo "       Download CARLA 0.9.16 (Linux) in a browser, copy it to $CARLA_DIR/carla-0.9.16.tar.gz with scp, then re-run this script."
      exit 1
    fi
  fi
  tar -xzf carla-0.9.16.tar.gz && rm carla-0.9.16.tar.gz
  [ -f "$CARLA_DIR/CarlaUE4.sh" ] || { echo "ERROR: CarlaUE4.sh not at $CARLA_DIR; the archive extracted into a sub-folder. Move its contents up so $CARLA_DIR/CarlaUE4.sh exists, then re-run."; exit 1; }
fi
grep -q "CARLA_ROOT" "$HOME/.bashrc" || echo "export CARLA_ROOT=$CARLA_DIR" >> "$HOME/.bashrc"

if ! command -v uv >/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
cd "$REPO"
uv venv venv-sim --python 3.12
# uv-managed Pythons ship without pip: install with `uv pip` against this venv.
VIRTUAL_ENV="$REPO/venv-sim" uv pip install -r requirements-sim.txt || {
  echo "carla wheel install failed? try the wheel shipped with CARLA:"
  echo "  VIRTUAL_ENV=$REPO/venv-sim uv pip install $CARLA_DIR/PythonAPI/carla/dist/carla-0.9.16-*.whl"
  exit 1
}
echo "sim host ready ($(venv-sim/bin/python --version)): source $REPO/venv-sim/bin/activate; export CARLA_ROOT=$CARLA_DIR"
