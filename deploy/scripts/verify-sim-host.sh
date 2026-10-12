#!/usr/bin/env bash
# Verify the simulator host (A) after setup-sim-host.sh. Prints PASS/FAIL per check; exit 1 if any FAIL.
#   deploy/scripts/verify-sim-host.sh            # offline checks
#   deploy/scripts/verify-sim-host.sh --link     # + reach the inference server from deploy/hosts.env
set -uo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source deploy/scripts/hosts-env.sh
PY="${PY:-venv-sim/bin/python}"
export PYGAME_HIDE_SUPPORT_PROMPT=1
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

echo "== A. simulator host checks (cwd: $PWD)"
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader \
  | sed 's/^/      GPU: /' && pass "nvidia-smi" || fail "nvidia-smi not found (NVIDIA driver AMI required)"
[ "$(uname -m)" = "x86_64" ] && pass "x86_64 CPU (CARLA requirement)" || fail "CARLA needs x86_64, got $(uname -m)"
CARLA_DIR="${CARLA_ROOT:-$HOME/carla}"
[ -f "$CARLA_DIR/CarlaUE4.sh" ] && pass "CARLA binary at $CARLA_DIR/CarlaUE4.sh" || fail "CarlaUE4.sh not found under $CARLA_DIR (set CARLA_ROOT or run setup-sim-host.sh)"
[ -n "${CARLA_ROOT:-}" ] && pass "CARLA_ROOT exported ($CARLA_ROOT)" || fail "CARLA_ROOT not exported (add 'export CARLA_ROOT=~/carla' to ~/.bashrc and re-login)"
ldconfig -p 2>/dev/null | grep -q libvulkan && pass "libvulkan1 present" || fail "libvulkan1 missing (sudo apt-get install -y libvulkan1)"
command -v ffmpeg >/dev/null && pass "ffmpeg" || fail "ffmpeg missing (sudo apt-get install -y ffmpeg)"
command -v nc >/dev/null && pass "nc (netcat)" || fail "nc missing (sudo apt-get install -y netcat-openbsd)"
[ -x "$PY" ] && pass "venv-sim python ($($PY --version 2>&1))" || { fail "venv-sim missing ($PY). Run deploy/scripts/setup-sim-host.sh"; echo "== $fails FAIL"; exit 1; }
$PY -c "import carla, grpc, cv2, pygame, numpy, scipy, psutil, pynvml, pandas, matplotlib" 2>/dev/null \
  && pass "python deps (carla, grpcio, opencv, pygame, numpy, scipy, psutil, pynvml, pandas, matplotlib)" \
  || fail "python deps missing: $($PY -c 'import importlib
for m in ["carla","grpc","cv2","pygame","numpy","scipy","psutil","pynvml","pandas","matplotlib"]:
    try: importlib.import_module(m)
    except Exception: print(m, end=" ")')"
$PY -c "import torch" 2>/dev/null && echo "      note: torch is installed in venv-sim (not needed on A)" || pass "torch not installed (A stays torch-free)"
$PY -c "from module.remote.client import RemoteAlpamayoAdapter; from module.loops import closed_loop, open_loop" 2>/dev/null \
  && pass "carlamayo modules import without torch" || fail "module import failed: $($PY -c 'from module.loops import closed_loop' 2>&1 | tail -1)"
$PY -c "import carla" 2>/dev/null && [ -n "${CARLA_ROOT:-}" ] && PYTHONPATH="$CARLA_ROOT/PythonAPI/carla:${PYTHONPATH:-}" $PY -c "from agents.navigation.controller import VehiclePIDController" 2>/dev/null \
  && pass "CARLA PythonAPI agents (PID controller) importable" || fail "agents.navigation.controller not importable (CARLA_ROOT/PythonAPI/carla missing?)"
[ -f deploy/hosts.env ] && pass "deploy/hosts.env present (A=$SIM_HOST_IP, B=$INFERENCE_HOST_IP:$INFERENCE_PORT)" || fail "deploy/hosts.env missing (cp deploy/hosts.env.example deploy/hosts.env and edit)"
git log -1 --format='      commit %h %s' 2>/dev/null

if [ "${1:-}" = "--link" ]; then
  echo "== A -> B link checks (needs alpamayo_server.py running on B; --fake is enough)"
  [ -n "$INFERENCE_HOST_IP" ] || { fail "INFERENCE_HOST_IP not set"; echo "== $fails FAIL"; exit 1; }
  nc -zvw5 "$INFERENCE_HOST_IP" 22 >/dev/null 2>&1 && pass "TCP 22 to B (SSH / rsync)" || fail "TCP 22 to B blocked: security group on B must allow A (port 22)"
  nc -zvw5 "$INFERENCE_HOST_IP" "$INFERENCE_PORT" >/dev/null 2>&1 && pass "TCP $INFERENCE_PORT to B (gRPC)" \
    || fail "TCP $INFERENCE_PORT to B closed: server not running on B (ss -ltnp | grep $INFERENCE_PORT) or security group blocks $INFERENCE_PORT"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$INFERENCE_HOST" true 2>/dev/null && pass "ssh $INFERENCE_HOST without password (rsync works)" \
    || fail "ssh $INFERENCE_HOST needs a key: add the key pair to ~/.ssh/config (see docs/distributed/porting-guide.md)"
  env | grep -qi '^https\?_proxy=' && echo "      note: http(s)_proxy is set; if gRPC hangs, export no_grpc_proxy=$INFERENCE_HOST_IP"
  if $PY - "$INFERENCE_TARGET" <<'EOF'
import sys, numpy as np
from module import config as cfg
from module.remote.client import RemoteAlpamayoAdapter, RemoteInferenceError
target = sys.argv[1]
for version in ("fake", "1.5", "2", "1"):
    r = RemoteAlpamayoAdapter(target, expected_version=version, connect_timeout_sec=10)
    try:
        r.load_model()
        break
    except RemoteInferenceError as exc:
        if "serves Alpamayo" in str(exc):
            continue
        print(f"      {exc}"); sys.exit(1)
else:
    print("      could not match the server version"); sys.exit(1)
img = np.zeros((r.num_cameras, cfg.NUM_FRAMES, cfg.IMG_HEIGHT, cfg.IMG_WIDTH, 3), np.uint8)
d = r.prepare_model_input(img, np.zeros((16, 3), np.float32), np.tile(np.eye(3, dtype=np.float32), (16, 1, 1)), 0)
pred, extra = r.run_inference(None, None, d)
print(f"      server version={r.version} cameras={r.num_cameras} traj_samples={r.num_traj_samples} "
      f"pred={tuple(pred.shape)} rtt={extra['rtt_sec']:.3f}s request={extra['request_bytes']/1e6:.1f}MB")
r.close()
EOF
  then pass "gRPC round trip (handshake + Predict)"; else fail "gRPC round trip failed (see message above)"; fi
fi

echo "== $fails FAIL"
[ "$fails" -eq 0 ]
