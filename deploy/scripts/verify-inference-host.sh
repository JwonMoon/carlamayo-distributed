#!/usr/bin/env bash
# Verify the inference host (B) after setup-inference-host.sh. Prints PASS/FAIL per check; exit 1 if any FAIL.
#   deploy/scripts/verify-inference-host.sh          # environment + model access
#   deploy/scripts/verify-inference-host.sh --serving # + the local server answers on INFERENCE_PORT
set -uo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source deploy/scripts/hosts-env.sh
PY="${PY:-a_venv/bin/python}"
export PYGAME_HIDE_SUPPORT_PROMPT=1
VERSION_DIR="${ALPAMAYO_SUBMODULE:-third_party/alpamayo1.5}"
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

echo "== B. inference host checks (cwd: $PWD)"
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader \
  | sed 's/^/      GPU: /' && pass "nvidia-smi" || fail "nvidia-smi not found (NVIDIA driver AMI required)"
vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
[ "${vram:-0}" -ge 30000 ] && pass "VRAM ${vram} MiB (>= 30 GB for Alpamayo 1.5 bf16 + headroom)" \
  || fail "VRAM ${vram:-?} MiB: Alpamayo 1.5 bf16 needs ~24 GB; use --quantization or a bigger GPU"
df -h "$HOME" | awk 'NR==2{print "      disk free on $HOME: " $4}'
free_gb=$(df -BG "$HOME" | awk 'NR==2{gsub("G","",$4); print $4}')
[ "${free_gb:-0}" -ge 40 ] && pass "disk free ${free_gb} GB (model download ~22 GB)" || fail "disk free ${free_gb} GB < 40 GB"
[ -x "$PY" ] && pass "a_venv python ($($PY --version 2>&1))" || { fail "a_venv missing ($PY). Run deploy/scripts/setup-inference-host.sh"; echo "== $fails FAIL"; exit 1; }
[ -f "$VERSION_DIR/pyproject.toml" ] && pass "submodule $VERSION_DIR checked out" || fail "submodule $VERSION_DIR empty (git submodule update --init $VERSION_DIR)"
$PY -c "import torch; assert torch.cuda.is_available(); print('      torch', torch.__version__, 'cuda', torch.version.cuda, torch.cuda.get_device_name(0))" 2>/dev/null \
  && pass "torch with CUDA" || fail "torch cannot see CUDA ($($PY -c 'import torch; print(torch.__version__, torch.cuda.is_available())' 2>&1 | tail -1))"
$PY -c "import alpamayo1_5, transformers, grpc, grpc_health.v1, cv2, bitsandbytes, psutil, pynvml" 2>/dev/null \
  && pass "python deps (alpamayo1_5, transformers, grpcio+health, opencv, bitsandbytes, psutil, pynvml)" \
  || fail "python deps missing: $($PY -c 'import importlib
for m in ["alpamayo1_5","transformers","grpc","grpc_health.v1","cv2","bitsandbytes","psutil","pynvml"]:
    try: importlib.import_module(m)
    except Exception: print(m, end=" ")')"
$PY -c "import flash_attn" 2>/dev/null && pass "flash-attn importable" || echo "      note: flash-attn not importable (SDPA fallback; slower)"
$PY -c "from module.remote import server; from module.adapters import get_adapter; get_adapter('1.5')" 2>/dev/null \
  && pass "carlamayo server modules import" || fail "server module import failed: $($PY -c 'from module.remote import server' 2>&1 | tail -1)"
if command -v hf >/dev/null; then
  who=$(hf auth whoami 2>/dev/null | head -1)
  [ -n "$who" ] && pass "Hugging Face login ($who)" || fail "not logged in to Hugging Face (hf auth login; model gate must be approved)"
else
  fail "hf CLI not found (pip install -U huggingface_hub)"
fi
$PY - <<'EOF' 2>/dev/null && pass "model repo nvidia/Alpamayo-R1-1.5 accessible (gate approved)" || fail "cannot access nvidia/Alpamayo-R1-1.5 on Hugging Face (request access on the model page, then hf auth login)"
from huggingface_hub import HfApi
HfApi().model_info("nvidia/Alpamayo-R1-1.5")
EOF
[ -f deploy/hosts.env ] && pass "deploy/hosts.env present (bind IP $INFERENCE_HOST_IP:$INFERENCE_PORT)" || fail "deploy/hosts.env missing (cp deploy/hosts.env.example deploy/hosts.env and edit)"
my_ips="$( (ip -4 -o addr 2>/dev/null | awk '{print $4}' | cut -d/ -f1; hostname -I 2>/dev/null | tr ' ' '\n') | sort -u)"
echo "$my_ips" | grep -qx "$INFERENCE_HOST_IP" \
  && pass "this machine owns $INFERENCE_HOST_IP" || fail "INFERENCE_HOST_IP=$INFERENCE_HOST_IP is not an address of this machine ($(echo $my_ips | tr '\n' ' ')); fix deploy/hosts.env"
git log -1 --format='      commit %h %s' 2>/dev/null

if [ "${1:-}" = "--serving" ]; then
  echo "== local server checks"
  if command -v ss >/dev/null; then listening=$(ss -ltn 2>/dev/null | grep -c ":$INFERENCE_PORT "); else listening=$($PY -c "import socket,sys; s=socket.socket(); s.settimeout(2); sys.stdout.write('1' if s.connect_ex(('$INFERENCE_HOST_IP', $INFERENCE_PORT))==0 else '0')"); fi
  [ "${listening:-0}" != "0" ] && pass "something listens on :$INFERENCE_PORT" || fail "nothing listens on :$INFERENCE_PORT (start alpamayo_server.py in tmux)"
  $PY - "$INFERENCE_HOST_IP:$INFERENCE_PORT" <<'EOF' && pass "gRPC health = SERVING" || fail "gRPC health not SERVING yet (model still loading / warming up?)"
import sys, grpc
from grpc_health.v1 import health_pb2, health_pb2_grpc
ch = grpc.insecure_channel(sys.argv[1]); grpc.channel_ready_future(ch).result(timeout=5)
st = health_pb2_grpc.HealthStub(ch).Check(health_pb2.HealthCheckRequest(), timeout=5).status
print("      health:", health_pb2.HealthCheckResponse.ServingStatus.Name(st)); sys.exit(0 if st == health_pb2.HealthCheckResponse.SERVING else 1)
EOF
fi

echo "== $fails FAIL"
[ "$fails" -eq 0 ]
