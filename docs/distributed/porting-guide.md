# 포팅 가이드: 새 인스턴스 두 대에 분산 Carlamayo 구성하기

이 문서만 보고 **처음부터** 새 AWS 인스턴스 두 대(시뮬레이터 A, 추론 B)에 환경을 만들고, 동작을
확인하는 절차다. 소요 시간은 인스턴스가 준비된 상태에서 약 1.5~3시간이다(모델 22 GB 다운로드와
CARLA 바이너리 다운로드가 대부분). 각 절 끝의 **확인** 명령이 통과하면 다음 절로 간다.

문서 역할 구분:
- 이 문서: 포팅(최초 구성 + 동작 확인). 한 번 끝나면 다시 볼 일이 없다.
- [demo-runbook.md](demo-runbook.md): 구성이 끝난 뒤 데모를 돌리는 순서(1부)와 모든 명령·옵션 참조(2부).
- [validation-checklist.md](validation-checklist.md): 단계별 검증 기록.
- 구조가 궁금하면 [distributed-architecture.md](distributed-architecture.md).

표기: **[A]** 시뮬레이터 호스트에서, **[B]** 추론 호스트에서, **[PC]** 작업 PC에서 실행.
명령의 `<A 사설 IP>`, `<B 사설 IP>` 같은 `<...>` 자리는 **자기 인스턴스 값으로 바꾼다.** runbook·checklist는 같은 뜻으로 `<A_IP>`/`<B_IP>`를 쓴다.

---

## 0. 준비물

### 0.1 인스턴스 사양

| 역할 | 요구 조건 | 원래 구성 | 비고 |
|---|---|---|---|
| **A 시뮬레이터** | **x86_64 필수**(CARLA는 UE4 x86 바이너리), GPU 8 GB 이상(CARLA 약 6 GB), vCPU 8, RAM 32 GB, 디스크 100 GB 이상 | g5.2xlarge (A10G 24 GB) | ARM 인스턴스 불가 |
| **B 추론** | **VRAM 30 GB 이상**(Alpamayo 1.5 bf16 약 24 GB + 여유), 디스크 80 GB 이상(모델 22 GB + 데이터), CPU 아키텍처 무관 | g6e.xlarge (L40S 48 GB) | 24 GB GPU면 `--quantization`으로만 가능 |

둘 다 같은 VPC·서브넷에 두고 **사설 IP**로 통신한다. 공인 IP는 운영자 접속(SSH, DCV)에만 쓴다.

### 0.2 AMI

두 가지 중 하나다. 어느 쪽이든 `nvidia-smi`가 GPU를 보여줘야 다음 단계로 간다.

| AMI | 드라이버 | 할 일 |
|---|---|---|
| **AWS Deep Learning Base GPU AMI (Ubuntu 22.04 또는 24.04)** (권장) | 들어 있음 | §2.5 건너뜀 |
| 일반 **Ubuntu** AMI (생 인스턴스) | 없음. `nvidia-smi: command not found` | **§2.5에서 드라이버를 먼저 깐다.** 드라이버 없이는 CARLA(Vulkan)가 안 뜬다 |

A에서 pygame 창을 DCV로 볼 계획이면 **Ubuntu 버전이 DCV 세션 방식을 결정**한다(§1.4). 이전 환경은 22.04 + 콘솔 세션이었고,
2026-10 포팅 환경은 26.04라 가상 세션만 가능했다.

| Ubuntu | GNOME | 콘솔 세션 (GNOME 화면, `DISPLAY=:0`) | 가상 세션 (XFCE) |
|---|---|---|---|
| 22.04 LTS | 42 | 가능 (이전 환경) | 가능 |
| 24.04 LTS | 46 | 가능 | 가능 |
| **26.04 LTS** | **50** | **불가.** GNOME 50은 X11 세션을 지원하지 않아 `WaylandEnable=false`를 줘도 Wayland로만 뜨고 DCV가 중계하지 못한다 | 가능 (현재 환경, §1.4 방식 B) |

Python은 OS 기본 버전을 쓰지 않는다. 설치 스크립트가 `uv`로 3.12를 내려받아 venv를 만들므로(A `venv-sim`, B `a_venv`) 26.04의 3.14도 문제 없다.
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

pygame 창을 보려면 A에 DCV 서버를 설치하고 세션을 만든다. DCV 없이도 open-loop·closed-loop(`--no-pygame-ui`)·측정은
전부 가능하고, 영상은 `runs/<run_id>/*.mp4`로 남으므로 scp로 받아 보면 된다.

세션 방식은 둘이다. **Ubuntu 버전에 따라 고른다**(§0.2 표). 공통 설치(1.4.1)를 한 뒤 방식 A 또는 B 중 하나만 한다.

| | 방식 A: 콘솔 세션 | 방식 B: 가상 세션 |
|---|---|---|
| X 서버 | 부팅 때 gdm이 GPU 위에 띄운 Xorg `:0`을 DCV가 중계 | DCV가 세션마다 자체 X 서버(`Xdcv`)를 띄움 |
| 화면 | 우분투 GNOME 바탕화면 (이전 환경과 같음) | XFCE 바탕화면 |
| 필요한 것 | `ubuntu-desktop-minimal`, `gdm3`, Wayland 끄기, `nvidia-xconfig`, `graphical.target` | `xfce4`, `nice-xdcv`, `/etc/dcv/dcvsessioninit`, `multi-user.target` |
| 되는 OS | 22.04, 24.04 | 22.04, 24.04, **26.04** |
| `DISPLAY` | `:0` | `:0` (gdm을 꺼 두면 첫 가상 세션이 `:0`을 받음) |

#### 1.4.1 공통: DCV 패키지와 계정 (두 방식 모두)

전제: NVIDIA 드라이버(§2.5). 보안그룹 8443(§1.2).

```bash
# [A]  DCV 패키지: AWS "NICE DCV 다운로드" 페이지에서 Ubuntu 버전(2204 또는 2404) x86_64 tgz 주소를 복사해 넣는다.
#      26.04용 패키지는 없으며 2404 패키지가 26.04에서 설치·동작한다(2026-10 확인).
cd /tmp && wget https://d1uj6qtbmh3dt5.cloudfront.net/NICE-GPG-KEY && gpg --import NICE-GPG-KEY
wget <nice-dcv-<버전>-ubuntu<2204|2404>-x86_64.tgz 주소> && tar xzf nice-dcv-*-ubuntu*-x86_64.tgz && cd nice-dcv-*-x86_64
sudo apt-get install -y ./nice-dcv-server_*.deb ./nice-xdcv_*.deb ./nice-dcv-gl_*.deb ./nice-dcv-web-viewer_*.deb
#   nice-xdcv = 가상 세션용 X 서버(방식 B 필수), nice-dcv-gl = 세션 안 GL 가속(선택, pygame에는 불필요)
#   마지막의 "N: Download is performed unsandboxed ..." 는 안내일 뿐 오류가 아니다.
sudo usermod -aG video dcv
sudo systemctl enable --now dcvserver
sudo passwd ubuntu                               # DCV 로그인에 쓸 비밀번호 ("BAD PASSWORD" 경고가 떠도 적용됨)
```

접속은 브라우저 또는 DCV 클라이언트로 `https://<A 공인 IP>:8443`, `ubuntu`로 로그인. 자체 서명 인증서라 처음 한 번은 경고를 수락해야 한다.
**인스턴스를 stop/start 하면 세션이 사라진다.** 접속 전에 `start_dcv` alias(각 방식 끝에 있음)를 한 번 친다.

#### 1.4.2 방식 A: 콘솔 세션 (Ubuntu 22.04 / 24.04, GNOME 화면)

```bash
# [A]  1) GNOME 데스크톱 + 로그인 관리자
sudo apt-get update && sudo apt-get install -y ubuntu-desktop-minimal gdm3
# 2) DCV는 Xorg만 중계하므로 Wayland를 끈다. [daemon] 아래에 WaylandEnable=false 가 있어야 한다
sudo sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=false/' /etc/gdm3/custom.conf
grep -n WaylandEnable /etc/gdm3/custom.conf      # 없으면 [daemon] 아래에 직접 한 줄 추가
# 3) 모니터 없는 NVIDIA GPU 위에서 Xorg가 뜨게
sudo nvidia-xconfig --preserve-busid --enable-all-gpus
# 4) 부팅 때 gdm이 뜨게 하고 재부팅
sudo systemctl set-default graphical.target && sudo systemctl enable gdm
sudo reboot
```
```bash
# 재접속 후
ps aux | grep -c '[X]org'                        # 1 이상이어야 함. 0이면 journalctl -u gdm -n 30 확인
sudo dcv create-session --type console --owner ubuntu simulator-session
dcv list-sessions                                # Session: 'simulator-session' (owner:ubuntu type:console)
```
```bash
# ~/.bashrc
alias start_dcv='sudo systemctl start dcvserver && (dcv list-sessions | grep -q simulator-session || sudo dcv create-session --type console --owner ubuntu simulator-session) && dcv list-sessions'
```

journal에 `New session ... type 'wayland'` 나 `Running GNOME Shell ... as a Wayland display server` 가 찍히면 그 OS의 GNOME은 X11을
지원하지 않는 것이다(26.04). 이 경우 콘솔 세션은 불가능하니 방식 B로 간다.

#### 1.4.3 방식 B: 가상 세션 (Ubuntu 26.04, 또는 콘솔 세션이 안 될 때)

GNOME은 Xdcv 위에서 뜨지 않으므로(26.04에서는 1초 만에 종료) 데스크톱은 **XFCE**를 쓴다.

```bash
# [A]  1) XFCE. 설치 중 "Configuring lightdm: gdm3 / lightdm" 선택 화면이 뜨면 아무거나 Ok (어차피 켜지 않는다)
sudo apt-get update && sudo apt-get install -y xfce4 xfce4-terminal
sudo systemctl disable --now lightdm 2>/dev/null; sudo systemctl disable --now gdm 2>/dev/null
sudo systemctl set-default multi-user.target     # 로그인 화면(gdm/lightdm)은 가상 세션에 필요 없고 GPU 메모리만 쓴다
# 2) 가상 세션이 띄울 데스크톱 지정
printf '#!/bin/sh\nexec startxfce4\n' | sudo tee /etc/dcv/dcvsessioninit
sudo chmod +x /etc/dcv/dcvsessioninit
# 3) 가상 세션
sudo dcv create-session --type virtual --owner ubuntu simulator-session
dcv list-sessions                                # Session: 'simulator-session' (owner:ubuntu type:virtual) 가 남아 있어야 함
```
```bash
# ~/.bashrc
alias start_dcv='sudo systemctl start dcvserver && (dcv list-sessions | grep -q simulator-session || sudo dcv create-session --type virtual --owner ubuntu simulator-session) && dcv list-sessions'
```

세션이 `list-sessions`에서 바로 사라지면 데스크톱 시작이 실패한 것이다. `sudo tail -n 30 /var/log/dcv/dcv-xsession.ubuntu.simulator-session.log`에
`Init script exited normally`가 1초 안에 찍히면 그 경우이고, `dcvsessioninit`이 없거나(기본값 `/etc/X11/Xsession` → GNOME) XFCE가 안 깔린 것이다.

XFCE 바탕화면에서 터미널은 상단 패널의 터미널 아이콘 또는 바탕화면 오른쪽 클릭 → Applications → Terminal Emulator.
CARLA 서버·B 서버는 지금까지처럼 SSH 터미널(`tmux`)에서 켜고, pygame 창이 필요한 `carlamayo.py`만 이 터미널에서 실행한다.

#### DISPLAY 번호

두 방식 모두 보통 `:0`이다(콘솔은 항상, 가상은 gdm을 꺼 둔 경우). `carlamayo.py`는 DCV 세션 안의 터미널에서 실행하면 자동으로 맞고,
SSH 터미널에서 띄우려면 `export DISPLAY=:0`. 다르면 `dcv describe-session simulator-session | grep -i display`로 확인한다.
접속이 Connecting이나 로딩에서 멈추면 §8.

---

## 2. 공통: 저장소와 호스트 설정 파일

두 인스턴스 모두에서:

```bash
git clone https://github.com/jwonmoon/carlamayo-distributed.git ~/carlamayo
cd ~/carlamayo
git checkout main                              # 기본 브랜치(main). 개발 브랜치는 claude/nice-planck-dec7fo
git log -1 --oneline                           # 두 인스턴스가 같은 커밋인지 메모
cp deploy/hosts.env.example deploy/hosts.env
nano deploy/hosts.env                          # SIM_HOST_IP, INFERENCE_HOST_IP, INFERENCE_SSH_USER 를 자기 값으로
```

`deploy/hosts.env`는 git에 올라가지 않는다(`.gitignore`). 스크립트들(`verify-*.sh`, `fetch_server_profile.sh`,
`sync-dataset-to-inference-host.sh`)이 이 파일을 읽어 B 주소를 안다. `carlamayo.py --inference-server`와
`alpamayo_server.py --host`는 명령줄에 IP를 직접 쓴다.

> 두 인스턴스의 **커밋이 같아야** 한다. 다르면 핸드셰이크에서 `NUM_FRAMES: client 4 != server …` 같은 오류로 시작을 거부한다.

### 2.5 NVIDIA 드라이버 (두 대 공통, 생 Ubuntu AMI일 때)

`nvidia-smi`가 이미 GPU를 보여주면 이 절은 건너뛴다. 아니면 **A·B 모두** 아래를 한다(약 10분 + 재부팅).

```bash
# [A], [B]
sudo apt-get update && sudo apt-get install -y ubuntu-drivers-common
ubuntu-drivers devices                        # "recommended"가 붙은 nvidia-driver-5xx 번호 확인
sudo apt-get install -y nvidia-driver-<번호>  # 예: nvidia-driver-535. "-server" 변종은 쓰지 않는다(DCV GL에 필요)
sudo reboot
```

```bash
# 재접속 후
nvidia-smi                                    # GPU 이름(A10G / L40S)과 드라이버 버전이 나와야 한다
```

| GPU | 최소 드라이버 | 비고 |
|---|---|---|
| g5 (A10G) | 535 이상 | CARLA Vulkan 렌더링, DCV 가상 세션 |
| g6e (L40S) | 535 이상 | torch 2.8 휠에 CUDA 런타임이 들어 있어 CUDA Toolkit은 불필요 |

- 재부팅 뒤에도 `nvidia-smi`가 실패하면 `dmesg | grep -i nvidia`로 모듈 로드 오류를 본다. **Secure Boot가 켜진 AMI**에서는
  서명되지 않은 모듈이 막혀 실패하는데, EC2에서는 MOK 등록이 어려우므로 Deep Learning Base GPU AMI로 인스턴스를 다시 만드는 쪽이 빠르다.
- 설치 스크립트(§3.1, §4.1)는 `nvidia-smi`가 없으면 경고만 찍고 계속 진행한다. 경고가 보이면 여기로 돌아온다.

---

## 3. [A] 시뮬레이터 호스트

### 3.1 설치 (약 20분, CARLA 다운로드 포함)

```bash
# [A]
cd ~/carlamayo && deploy/scripts/setup-sim-host.sh
source ~/.bashrc            # CARLA_ROOT 반영
```

스크립트가 하는 일: `ffmpeg`, `libvulkan1`, `rsync`, `netcat`, `curl` 설치 → `uv`로 **Python 3.12** 내려받아 `venv-sim` 생성(OS 기본 Python과 무관. carla 휠은 3.10~3.12만 있고 26.04는 3.14) → CARLA 0.9.16 바이너리를 `~/carla`에 풀기 →
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
| 0 | A·B 모두 `nvidia-smi` 동작 | GPU 이름·드라이버 버전 출력 (§0.2, §2.5) | ☐ |
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
| `setup-sim-host.sh`가 apt 뒤 조용히 끝남, `~/carla/carla-0.9.16.tar.gz`가 0바이트 | CARLA 다운로드 실패(옛 스크립트는 오류를 숨겼음) | `git pull` 후 재실행하면 오류가 보인다. 그래도 안 받아지면 브라우저로 CARLA 0.9.16 Linux를 받아 `scp`로 `~/carla/carla-0.9.16.tar.gz`에 올리고 재실행 |
| `carla` 휠 설치 실패 | PyPI에 해당 Python 휠 없음(venv가 3.12가 아님) | `ls venv-sim/bin/python* && venv-sim/bin/python --version`이 3.12인지. 아니면 `rm -rf venv-sim` 후 스크립트 재실행. 그래도 안 되면 `VIRTUAL_ENV=$PWD/venv-sim uv pip install ~/carla/PythonAPI/carla/dist/carla-0.9.16-*.whl` |
| `agents.navigation.controller` 없음 | `CARLA_ROOT` 미설정 | `export CARLA_ROOT=~/carla` (bashrc 확인) |
| `nvidia-smi: command not found` | 일반 Ubuntu AMI라 드라이버 없음 | §2.5 |
| DCV 웹 접속이 Connecting·로딩에서 멈춤 (로그인 창도 안 나옴) | 8443 미개방·공인 IP 변경, dcvserver 중지, 브라우저가 자체 서명 인증서 거부 | 로컬에서 `nc -zv <A 공인 IP> 8443`(§1.2); `sudo systemctl restart dcvserver`; 주소를 직접 열어 경고 수락하거나 네이티브 DCV 클라이언트 |
| 로그인은 되는데 화면이 계속 로딩 | 세션 없음(stop/start 뒤), 데스크톱 환경 없음, 세션 방식이 OS와 안 맞음 | `dcv list-sessions` 비면 `start_dcv`; `dpkg -l \| grep -E 'ubuntu-desktop\|xfce4'` 비면 §1.4.2/§1.4.3의 1); 26.04에서 `type:console`이면 close-session 후 방식 B |
| journal에 `type 'wayland'`, `Running GNOME Shell ... as a Wayland display server` (콘솔 세션, `WaylandEnable=false`인데도) | 그 OS의 GNOME(50, 26.04)이 X11 미지원. 콘솔 세션 불가 | 방식 B(§1.4.3)로. 또는 A를 22.04/24.04 AMI로 다시 만든다 |
| 가상 세션이 만들어진 직후 사라짐 (`create-session` 뒤 `list-sessions` 비어 있음) | 세션 안 데스크톱이 바로 종료. `dcv-xsession.*.log`에 `Init script exited normally` | XFCE 설치 + `/etc/dcv/dcvsessioninit`에 `exec startxfce4`(§1.4.3). GNOME은 Xdcv 위에서 안 뜬다 |
| `nvidia-smi: command not found` 인데 DCV만 문제 | 드라이버는 CARLA용. DCV 가상 세션은 드라이버 없이도 뜸 | 원인을 DCV 쪽(위 행들)에서 찾는다. 드라이버는 §2.5에서 어차피 깐다 |
| CARLA가 바로 죽음 | Vulkan 없음 / GPU 드라이버 | `sudo apt-get install -y libvulkan1`, `nvidia-smi` 확인 |
| B `uv sync`에서 flash-attn 빌드 실패 | `nvcc` 없음 | 스크립트가 자동으로 제외. 느리지만 동작 |
| 모델 다운로드 401/403 | 게이트 미승인 또는 토큰 없음 | 모델 페이지에서 접근 요청, `hf auth login` |
| `no inference server at …:50051 after 30s` | B 서버 안 뜸 / 보안그룹 / 프록시 | §5 표 |
| `serves Alpamayo '2' but --version '1.5'` | A·B `--version` 불일치 | 맞춘다 |
| `NUM_FRAMES: client 4 != server …` | 커밋 불일치 | 양쪽 `git pull` |
| pygame 창이 안 뜸 | DCV 세션 밖 | DCV 세션 안의 터미널, 또는 `export DISPLAY=<describe-session의 display 값>`(§1.4), 또는 `--no-pygame-ui` |
| 영상이 없음 | 강제 종료 | Esc/Ctrl+C로 종료 |

---

## 9. 원래 구성과 다른 점을 적어 둘 곳

인스턴스 종류·OS·GPU가 다르면 [validation-checklist.md](validation-checklist.md) 0단계 표와
[changes-from-upstream.md](changes-from-upstream.md) 검증 기록에 한 줄 남긴다(예: "B를 g6e.2xlarge로, flash-attn 빌드 성공").
`deploy/systemd/alpamayo-server.service`를 쓰려면 `<INFERENCE_HOST_IP>`와 경로를 바꾼 뒤 복사한다.
