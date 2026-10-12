# 포팅 가이드: 새 인스턴스 두 대에 분산 Carlamayo 구성하기

이 문서만 보고 **처음부터** 새 AWS 인스턴스 두 대(시뮬레이터 A, 추론 B)에 환경을 만들고, 동작을
확인하는 절차다. 소요 시간은 인스턴스가 준비된 상태에서 약 1.5~3시간이다(모델 22 GB 다운로드와
CARLA 바이너리 다운로드가 대부분). 각 절 끝의 **확인** 명령이 통과하면 다음 절로 간다.

문서 역할 구분:
- 이 문서: 포팅(최초 구성 + 동작 확인). 한 번 끝나면 다시 볼 일이 없다.
- [demo-runbook.md](demo-runbook.md): 구성이 끝난 뒤 데모를 돌리는 순서.
- [cheatsheet.md](cheatsheet.md): 모든 명령·옵션 참조. [validation-checklist.md](validation-checklist.md): 단계별 검증 기록.
- 구조가 궁금하면 [distributed-architecture.md](distributed-architecture.md).

표기: **[A]** 시뮬레이터 호스트에서, **[B]** 추론 호스트에서, **[PC]** 작업 PC에서 실행.
예시 IP(`172.31.38.219`, `172.31.20.213`)는 원래 구성의 값이며 **자기 인스턴스 값으로 바꾼다.**

---

## 0. 준비물

### 0.1 인스턴스 사양

| 역할 | 요구 조건 | 원래 구성 | 비고 |
|---|---|---|---|
| **A 시뮬레이터** | **x86_64 필수**(CARLA는 UE4 x86 바이너리), GPU 8 GB 이상(CARLA 약 6 GB), vCPU 8, RAM 32 GB, 디스크 100 GB 이상 | g5.2xlarge (A10G 24 GB) | ARM 인스턴스 불가 |
| **B 추론** | **VRAM 30 GB 이상**(Alpamayo 1.5 bf16 약 24 GB + 여유), 디스크 80 GB 이상(모델 22 GB + 데이터), CPU 아키텍처 무관 | g6e.xlarge (L40S 48 GB) | 24 GB GPU면 `--quantization`으로만 가능 |

둘 다 같은 VPC·서브넷에 두고 **사설 IP**로 통신한다. 공인 IP는 운영자 접속(SSH, DCV)에만 쓴다.

### 0.2 AMI

NVIDIA 드라이버가 들어 있는 이미지를 고른다. 두 대 모두 **AWS Deep Learning Base GPU AMI (Ubuntu 22.04)** 가
가장 간단하다. 직접 설치하는 경우 Ubuntu 22.04 + `nvidia-driver-5xx`. 확인: `nvidia-smi`가 GPU를 보여줘야 한다.
B에서 flash-attn을 빌드하려면 CUDA Toolkit(`nvcc`)이 있어야 하지만, 없으면 자동으로 SDPA 폴백을 쓴다(느릴 뿐 동작).

### 0.3 계정·권한

| 항목 | 필요한 것 |
|---|---|
| AWS | 두 인스턴스에 SSH 가능한 **키페어 하나**(같은 pem을 A·B에 등록하면 A→B 접속이 쉽다), 보안그룹 편집 권한(없으면 관리자에게 §1.2 규칙을 요청) |
| GitHub | 이 저장소 읽기 권한 |
| Hugging Face | 계정 + **`nvidia/Alpamayo-R1-1.5` 모델 게이트 승인**(모델 페이지에서 요청, 승인까지 수 시간~수일) + 토큰(read) |
| NICE DCV | A에 DCV 서버 설치(pygame 창을 보기 위해). AWS 라이선스로 EC2에서는 무료. 또는 SSH 터미널 + `--no-pygame-ui`로 창 없이 진행 가능 |

---

## 1. AWS 설정

### 1.1 인스턴스 생성 후 기록할 것

| 값 | A | B |
|---|---|---|
| 사설 IP | `__.__.__.__` | `__.__.__.__` |
| 보안그룹 ID | `sg-________` | `sg-________` |
| SSH 사용자 | `ubuntu` (Ubuntu AMI) / `ec2-user` (Amazon Linux) | 같음 |

### 1.2 보안그룹 규칙

| 대상 | 방향 | 포트 | 소스 | 용도 |
|---|---|---|---|---|
| A | 인바운드 | TCP 22 | 운영자 IP | SSH |
| A | 인바운드 | TCP 8443 | 운영자 IP | NICE DCV |
| B | 인바운드 | TCP 22 | **A의 보안그룹 ID** (또는 운영자 IP도) | A→B SSH, rsync |
| B | 인바운드 | TCP **50051** | **A의 보안그룹 ID** | gRPC 추론 |

가장 간단한 방법은 B 인스턴스에 A의 보안그룹을 **추가로 연결**하는 것이다(A의 그룹이 VPC 내부 전체를 허용한다면).
CARLA 포트(2000~2002, 8000)는 어디에도 열지 않는다. gRPC는 평문이므로 VPC 밖으로 노출하지 않는다.

> 증상으로 구분: B의 규칙이 없으면 A에서 `nc -zv <B IP> 50051`이 **멈추다가 timed out**. 규칙은 있는데 서버가 안 떠 있으면
> **즉시 refused**.

### 1.3 A → B SSH 키

A에서 B로 `ssh`/`rsync`가 비밀번호 없이 되어야 프로파일 회수 스크립트가 동작한다. 키페어 pem을 A에 올리고 `~/.ssh/config`에 등록한다.

```bash
# [PC]
scp -i ~/.ssh/<키페어>.pem ~/.ssh/<키페어>.pem ubuntu@<A 공인 IP>:~/.ssh/
# [A]
chmod 600 ~/.ssh/<키페어>.pem
cat >> ~/.ssh/config <<'EOF'
Host <B 사설 IP>
    User ubuntu
    IdentityFile ~/.ssh/<키페어>.pem
    StrictHostKeyChecking accept-new
EOF
ssh <B 사설 IP> hostname      # B의 호스트명이 나오면 통과
```

### 1.4 NICE DCV (A, 선택)

pygame 창을 보려면 A에 DCV 서버를 설치하고 가상 세션을 만든다(AWS 문서 "NICE DCV 설치 – Ubuntu" 절차 그대로).
DCV 클라이언트로 `https://<A 공인 IP>:8443` 접속. DCV 없이도 open-loop·closed-loop(`--no-pygame-ui`)·측정은 전부 가능하고,
영상은 `runs/<run_id>/*.mp4`로 남으므로 scp로 받아 보면 된다.

---

## 2. 공통: 저장소와 호스트 설정 파일

두 인스턴스 모두에서:

```bash
git clone https://github.com/jwonmoon/carlamayo-my-distributed.git ~/carlamayo
cd ~/carlamayo
git checkout claude/nice-planck-dec7fo        # 기본 브랜치. 이후 main으로 바뀌면 그쪽
git log -1 --oneline                           # 두 인스턴스가 같은 커밋인지 메모
cp deploy/hosts.env.example deploy/hosts.env
nano deploy/hosts.env                          # SIM_HOST_IP, INFERENCE_HOST_IP, INFERENCE_SSH_USER 를 자기 값으로
```

`deploy/hosts.env`는 git에 올라가지 않는다(`.gitignore`). 스크립트들(`verify-*.sh`, `fetch_server_profile.sh`,
`sync-dataset-to-inference-host.sh`)이 이 파일을 읽어 B 주소를 안다. `carlamayo.py --inference-server`와
`alpamayo_server.py --host`는 명령줄에 IP를 직접 쓴다.

> 두 인스턴스의 **커밋이 같아야** 한다. 다르면 핸드셰이크에서 `NUM_FRAMES: client 4 != server …` 같은 오류로 시작을 거부한다.

---

## 3. [A] 시뮬레이터 호스트

### 3.1 설치 (약 20분, CARLA 다운로드 포함)

```bash
# [A]
cd ~/carlamayo && deploy/scripts/setup-sim-host.sh
source ~/.bashrc            # CARLA_ROOT 반영
```

스크립트가 하는 일: `python3.10`, `ffmpeg`, `libvulkan1`, `rsync`, `netcat` 설치 → CARLA 0.9.16 바이너리를 `~/carla`에 풀기 →
`CARLA_ROOT` 등록 → `venv-sim`(torch 없음) 생성 후 `requirements-sim.txt` 설치.
`carla` 휠이 PyPI에 없다고 나오면 안내대로 `pip install ~/carla/PythonAPI/carla/dist/carla-0.9.16-*.whl`.

### 3.2 확인

```bash
# [A]
cd ~/carlamayo && source venv-sim/bin/activate && export CARLA_ROOT=~/carla
deploy/scripts/verify-sim-host.sh
```

기대: 모든 줄이 `PASS`, 마지막 줄 `== 0 FAIL`. 항목: nvidia-smi, x86_64, CARLA 바이너리, `CARLA_ROOT`, Vulkan, ffmpeg, nc,
venv-sim, 파이썬 의존성, torch 없음, carlamayo 모듈 import, CARLA PythonAPI agents, hosts.env.

CARLA가 실제로 뜨는지도 한 번 본다:
```bash
# [A]
tmux new -s carla
cd ~/carla && ./CarlaUE4.sh -RenderOffScreen -quality-level=Epic      # Ctrl+B, D 로 빠져나오기
nvidia-smi                                                             # CarlaUE4 약 6 GB
python -c "import carla; c=carla.Client('localhost',2000); c.set_timeout(10); print(c.get_server_version())"   # 0.9.16
```

### 3.3 단위 테스트 (선택, GPU·CARLA 불필요)

```bash
# [A]
pip install pytest && PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python -m pytest -q tests   # 160개 이상 passed
```

---

## 4. [B] 추론 호스트

### 4.1 설치 (약 15분 + flash-attn 빌드 시 20~40분)

```bash
# [B]
cd ~/carlamayo && deploy/scripts/setup-inference-host.sh
```

스크립트가 하는 일: `uv` 설치 → `third_party/alpamayo1.5` 서브모듈 체크아웃 → `a_venv`(Python 3.12) 생성 →
`uv sync`(torch 2.8, transformers, flash-attn …) → alpamayo1.5 패키지와 `requirements-inference.txt` 설치 → import 확인.
flash-attn 빌드가 실패하면 자동으로 빼고 진행한다(SDPA 폴백).

### 4.2 Hugging Face 로그인

```bash
# [B]
source a_venv/bin/activate
hf auth login            # read 토큰 입력
hf auth whoami           # 계정 이름
```

### 4.3 확인

```bash
# [B]
cd ~/carlamayo && source a_venv/bin/activate
deploy/scripts/verify-inference-host.sh
```

기대: `== 0 FAIL`. 항목: nvidia-smi, VRAM ≥ 30 GB, 디스크 ≥ 40 GB, a_venv, 서브모듈, torch+CUDA, 의존성, flash-attn(참고),
서버 모듈 import, HF 로그인, **모델 게이트 접근 가능**, hosts.env, `INFERENCE_HOST_IP`가 이 머신의 주소인지.

---

## 5. A ↔ B 연결 확인 (모델 없이, 5분)

B에서 GPU·가중치 없이 가짜 서버를 띄우고 A에서 전 구간을 확인한다.

```bash
# [B]
cd ~/carlamayo && source a_venv/bin/activate
python alpamayo_server.py --fake --host <B 사설 IP> --port 50051
#   마지막 줄: SERVING Fake Alpamayo ... warmed_up=True
```
```bash
# [A]  (다른 터미널)
cd ~/carlamayo && source venv-sim/bin/activate
deploy/scripts/verify-sim-host.sh --link
```

기대 출력의 뒷부분:
```
== A -> B link checks
PASS  TCP 22 to B (SSH / rsync)
PASS  TCP 50051 to B (gRPC)
PASS  ssh ubuntu@<B IP> without password (rsync works)
      server version=fake cameras=4 traj_samples=1 pred=(1, 1, 1, 64, 3) rtt=0.1xxs request=0.5MB
PASS  gRPC round trip (handshake + Predict)
== 0 FAIL
```
`rtt`는 VPC 내부에서 0.1~0.3 s가 정상이다(원래 구성 실측 0.177 s). 끝나면 B의 가짜 서버를 Ctrl+C로 내린다.

| FAIL | 원인 | 조치 |
|---|---|---|
| TCP 22 / 50051 blocked | B 보안그룹 | §1.2 |
| TCP 50051 closed (refused) | B에서 서버 안 뜸 / `--host` IP 오타 | B에서 `ss -ltnp \| grep 50051` |
| ssh needs a key | A의 `~/.ssh/config` | §1.3 |
| gRPC round trip failed + `no inference server … after 30s` | 위 둘 중 하나, 또는 A의 `https_proxy` | `export no_grpc_proxy=<B IP>` |

---

## 6. 실제 모델로 동작 확인 (30분~1시간, 첫 모델 다운로드 포함)

### 6.1 [B] 서버 기동

```bash
# [B]
tmux new -s server
cd ~/carlamayo && source a_venv/bin/activate
python alpamayo_server.py --version 1.5 --host <B 사설 IP> --port 50051
#   Model loaded in NNNs. / Warm-up inference done in N.Ns. / SERVING Alpamayo 1.5 ... cameras=4
# Ctrl+B, D
deploy/scripts/verify-inference-host.sh --serving      # 마지막에 gRPC health = SERVING
nvidia-smi                                              # 약 21~24 GB
```

첫 실행은 가중치 22 GB를 내려받는다. `401/403`이면 모델 게이트 미승인, 디스크 오류면 `df -h`.

### 6.2 [A] open-loop (CARLA 불필요, 원격 추론 경로 검증)

녹화 데이터가 없으면 먼저 만든다(CARLA가 떠 있어야 함, 1~2분):
```bash
# [A]
python data_collect.py        # 1~2분 뒤 Ctrl+C → carla_data/
```
```bash
# [A]
python carlamayo.py --loop open --version 1.5 --data-root carla_data --inference-server <B IP>:50051 --run-tag port-check
#   Run folder: runs/<run_id>  …  [Frame k] Inference: 2.xx s  반복
RUN=$(ls -t runs | head -1)
tools/fetch_server_profile.sh $RUN && python tools/analyze_run.py runs/$RUN && sed -n 1,30p runs/$RUN/summary.md
```
통과: `runs/<run_id>/carla_alpamayo_open_loop_result.mp4`와 `summary.md`가 생기고 headline에 `rtt_mean_s`, `inference_mean_s`가 있다.

### 6.3 [A] closed-loop 1~2분

```bash
# [A]  DCV 터미널(또는 SSH면 --no-pygame-ui 추가)
python carlamayo.py --loop closed --version 1.5 --inference-server <B IP>:50051 --run-tag port-check
#   2분쯤 보고 Esc (영상은 Esc/Ctrl+C로 끝내야 저장)
ls runs/$(ls -t runs | head -1)/*.mp4
```
통과: 차가 움직이고 터미널에 `[Frame k] Inference:`가 반복되며 종료 후 mp4가 있다.

여기까지 되면 포팅 완료다. 이후는 [demo-runbook.md](demo-runbook.md) 순서대로.

---

## 7. 완료 체크리스트

| # | 항목 | 확인 방법 | 상태 |
|---|---|---|---|
| 1 | A·B 같은 커밋 | `git log -1 --oneline` 비교 | ☐ |
| 2 | `deploy/hosts.env` 양쪽에 작성 | 파일 존재, IP 확인 | ☐ |
| 3 | A 환경 | `verify-sim-host.sh` → `0 FAIL` | ☐ |
| 4 | CARLA 기동 | `nvidia-smi`에 CarlaUE4, `get_server_version()` = 0.9.16 | ☐ |
| 5 | B 환경 + HF 게이트 | `verify-inference-host.sh` → `0 FAIL` | ☐ |
| 6 | A→B 네트워크·SSH·gRPC | `verify-sim-host.sh --link` (fake 서버) → `0 FAIL` | ☐ |
| 7 | 실제 서버 SERVING | `verify-inference-host.sh --serving` | ☐ |
| 8 | 원격 open-loop | mp4 + `summary.md` | ☐ |
| 9 | closed-loop | 주행 + mp4 | ☐ |

---

## 8. 자주 겪는 문제

| 증상 | 원인 | 조치 |
|---|---|---|
| `setup-inference-host.sh`가 `ensurepip` 오류로 멈춤 | 옛 버전 스크립트 | 최신 커밋으로 `git pull`(uv pip 사용) |
| `carla` 휠 설치 실패 | PyPI에 해당 Python 휠 없음 | `pip install ~/carla/PythonAPI/carla/dist/carla-0.9.16-*.whl` |
| `agents.navigation.controller` 없음 | `CARLA_ROOT` 미설정 | `export CARLA_ROOT=~/carla` (bashrc 확인) |
| CARLA가 바로 죽음 | Vulkan 없음 / GPU 드라이버 | `sudo apt-get install -y libvulkan1`, `nvidia-smi` 확인 |
| B `uv sync`에서 flash-attn 빌드 실패 | `nvcc` 없음 | 스크립트가 자동으로 제외. 느리지만 동작 |
| 모델 다운로드 401/403 | 게이트 미승인 또는 토큰 없음 | 모델 페이지에서 접근 요청, `hf auth login` |
| `no inference server at …:50051 after 30s` | B 서버 안 뜸 / 보안그룹 / 프록시 | §5 표 |
| `serves Alpamayo '2' but --version '1.5'` | A·B `--version` 불일치 | 맞춘다 |
| `NUM_FRAMES: client 4 != server …` | 커밋 불일치 | 양쪽 `git pull` |
| pygame 창이 안 뜸 | DCV 세션 밖 | DCV 터미널 또는 `export DISPLAY=:0` 또는 `--no-pygame-ui` |
| 영상이 없음 | 강제 종료 | Esc/Ctrl+C로 종료 |

---

## 9. 원래 구성과 다른 점을 적어 둘 곳

인스턴스 종류·OS·GPU가 다르면 [validation-checklist.md](validation-checklist.md) 0단계 표와
[changes-from-upstream.md](changes-from-upstream.md) 검증 기록에 한 줄 남긴다(예: "B를 g6e.2xlarge로, flash-attn 빌드 성공").
`deploy/systemd/alpamayo-server.service`를 쓰려면 `<INFERENCE_HOST_IP>`와 경로를 바꾼 뒤 복사한다.
