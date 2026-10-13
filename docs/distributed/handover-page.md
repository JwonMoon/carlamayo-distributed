# Carlamayo 분산 데모 인스턴스 인수인계

> 콜랩 페이지에 붙여 넣는 원본이다. `<...>` 칸을 실제 값으로 채운다. 명령과 옵션의 상세는
> 저장소 문서(§9)에 있고 이 페이지는 **받은 사람이 처음 30분과 매번 돌릴 때 필요한 것만** 담는다.

## 0. 개요

### 0.1 무엇인가

- CARLA 시뮬레이터(A)와 Alpamayo 1.5 추론 서버(B)를 **서로 다른 EC2 인스턴스**에서 돌리고 gRPC로 연결한 자율주행 데모.
- A의 `carlamayo.py`가 카메라 4장을 1초에 한 번 B로 보낸다.
- B가 돌려준 궤적으로 A의 차가 달린다(closed-loop).

### 0.2 출처: 오픈소스 Carlamayo를 개조한 것

| 구분 | 내용 |
|---|---|
| 원본 | [aveeslab/Carlamayo](https://github.com/aveeslab/Carlamayo). NVIDIA Alpamayo(1 / 1.5 / 2)를 CARLA에 붙여 open-loop(녹화 재생), closed-loop(모델이 운전), live-open-loop(오토파일럿 주행 위에 예측만 표시)으로 돌리는 프로젝트. **한 GPU 머신**에서 CARLA와 모델을 함께 돌린다 |
| 이 저장소 | 원본을 히스토리째 포크해 **모델 추론만 다른 인스턴스(B)로 분리**했다 |
| 원본 그대로인 것 | 데이터 수집, 세 가지 loop 모드, navigation·CFG·VQA, pygame 창. 설명은 README 상단 영문 부분 |
| 원본에 더한 것 | - gRPC 추론 서버 `alpamayo_server.py`와 원격 어댑터<br>- `carlamayo.py`의 `--inference-server` 플래그<br>- 실행별 결과 폴더 `runs/<run_id>/`, 프로파일링·분석 도구 `tools/`<br>- 두 호스트 설치·검증 스크립트 `deploy/`<br>- 한국어 운영 문서 `docs/distributed/` |

- 무엇을 어디에 왜 바꿨는지: `docs/distributed/changes-from-upstream.md`
- 원본의 새 변경을 가져오는 방법(`git remote add upstream ...`): README 끝

### 0.3 담당·저장소

| 항목 | 값 |
|---|---|
| 담당자 / 문의 | `<이름, 연락처>` |
| 저장소 | https://github.com/JwonMoon/carlamayo-my-distributed (브랜치 `main`, 두 인스턴스 모두 `~/carlamayo`에 클론됨) |
| 인계일 / 검증 상태 | `<날짜>` / validation-checklist `<N>`단계까지 ☑ |

---

## 1. 받은 것

| | **A: 시뮬레이터 호스트** | **B: 추론 호스트** |
|---|---|---|
| 역할 | CARLA 서버 + `carlamayo.py` + pygame 창 | `alpamayo_server.py` (모델 상주) |
| 인스턴스 타입 | g5.2xlarge (A10G 24 GB) | g6e.xlarge (L40S 48 GB) |
| 인스턴스 ID | `<i-...>` | `<i-...>` |
| 사설 IP | `<A_IP>` | `<B_IP>` |
| 공인 IP / DNS | `<...>` | `<...>` |
| SSH 사용자 | `<ubuntu 또는 ec2-user>` | `<ubuntu 또는 ec2-user>` |
| 키페어 | `<이름>.pem` (보관자: `<이름>`) | 같은 pem |
| 화면 접속 | NICE DCV `https://<A 공인 IP>:8443`, 계정 `<...>` | 없음 (SSH만) |
| 보안그룹 | `<sg-...>` | `<sg-...>` (A에서 TCP 22·50051 인바운드 허용됨) |

아래 명령의 `[A]`/`[B]`는 어느 인스턴스 터미널에서 치는지다. A의 pygame 창이 필요한 명령은 **DCV 세션 안의 터미널**에서 친다.

---

## 2. 처음 한 번 (약 30분)

| 순서 | 어디 | 할 일 | 확인 |
|---|---|---|---|
| 1 | 로컬 PC | pem을 받아 `chmod 400`, `ssh -i <pem> <user>@<A 공인 IP>`와 B 접속 | 프롬프트가 뜬다 |
| 2 | [B] | Hugging Face **본인 계정**으로 로그인: `source ~/carlamayo/a_venv/bin/activate && hf auth login` | `hf auth whoami`에 본인 계정 |
| 3 | [B] | 모델 게이트 승인 확인: https://huggingface.co/nvidia/Alpamayo-R1-1.5 에서 접근 요청(승인까지 수 시간~수일). 인계 전에 미리 신청한다 | 모델 페이지에 "Gated model: you have been granted access" |
| 4 | [A], [B] | `cd ~/carlamayo && git pull && cat deploy/hosts.env` | `SIM_HOST_IP=<A_IP>`, `INFERENCE_HOST_IP=<B_IP>`가 이 페이지와 같다 |
| 5 | [B] | `deploy/scripts/verify-inference-host.sh` | 마지막 줄 `== 0 FAIL` |
| 6 | [A] | `deploy/scripts/verify-sim-host.sh` | 마지막 줄 `== 0 FAIL` |

`FAIL` 줄에는 조치가 같이 찍힌다. 그래도 막히면 §7과 담당자.

---

## 3. 매번 실행하는 순서 (데모 기본 흐름)

| 순서 | 어디 | 명령 | 확인 방법 |
|---|---|---|---|
| 1 | [B] | `tmux new -s server` → `cd ~/carlamayo && source a_venv/bin/activate && python alpamayo_server.py --version 1.5 --host <B_IP> --port 50051` | 로그 마지막 `SERVING Alpamayo 1.5 ... warmed_up=True`. `nvidia-smi` 약 21~24 GB. `Ctrl+B, D`로 빠져나옴 |
| 2 | [A] | `nc -zv <B_IP> 50051` | `succeeded!` |
| 3 | [A] | `tmux new -s carla` → `cd ~/carla && ./CarlaUE4.sh -RenderOffScreen -quality-level=Epic` → `Ctrl+B, D` | `nvidia-smi`에 CarlaUE4 약 6 GB |
| 4 | [A] (DCV 터미널) | `cd ~/carlamayo && source venv-sim/bin/activate && export CARLA_ROOT=~/carla` | 이후 모든 A 명령의 전제 |
| 5 | [A] (DCV 터미널) | `python carlamayo.py --loop closed --version 1.5 --inference-server <B_IP>:50051 --run-tag sync` | 창(960×675)에 카메라 영상 + **빨간 궤적**, 아래 패널 `RUNNING \| frame N \| NN km/h \| inference 2.xx s`. 터미널에 `[Frame k] Inference: 2.xx s`가 약 1초마다 |
| 6 | [A] | 2~3분 보고 **`Esc`** | 터미널에 영상 저장 메시지. `ls runs/$(ls -t runs \| head -1)/` 에 `*.mp4`, `log.txt`, `profile_client*.csv` |

- 추론하는 동안 화면이 잠깐 멈추는 것이 정상이다(동기 모드: 세계를 멈추고 그 장면의 궤적을 받음).
- 창 조작: `Ctrl+P` 일시정지/재개, `Esc` 종료. **영상은 Esc나 Ctrl+C로 끝내야 저장된다.** 창을 강제로 닫으면 안 남는다.
- B는 1번 이후 **데모 내내 손대지 않는다.** 아래 §4의 모드 전환은 전부 A 쪽 플래그와 창 입력이다.

---

## 4. 모드 바꾸기 (A에서만, 5번 명령을 바꿔 친다)

| 모드 | 명령 (`BASE` = `python carlamayo.py --version 1.5 --inference-server <B_IP>:50051`) | 보이는 것 |
|---|---|---|
| open-loop (CARLA 불필요, 녹화 데이터 재생) | `BASE --loop open --data-root carla_data --run-tag remote` | 프레임마다 `[Frame k] Inference`, 끝나면 영상 위 궤적. `carla_data/`가 없으면 먼저 `python data_collect.py` 1~2분 뒤 Ctrl+C |
| closed-loop 비동기 (실시간성 비교용) | `BASE --loop closed --async --run-tag async` | 화면이 안 멈추고 10 Hz로 진행, 터미널에 `Trajectory age: N.NN s`. 커브에서 늦게 반응하는 것이 정상 |
| navigation + CFG (자연어 지시) | `BASE --loop closed --mode navigation --navigation-text "Turn right in 30m" --navigation-weight 1.5 --run-tag nav` | 패널 `Active nav: ...`. 주행 중 창 입력창에 `Turn left in 20m \| 1.5` Enter로 변경, `\| 1.0`만 치고 Enter로 해제. 지시는 **지울 때까지 매 추론에 들어간다** |
| VQA (질문·답) | `BASE --loop closed --mode vqa --vqa-question "What is ahead?" --run-tag vqa` | 차는 **정지**, 패널 `Answer:` 줄과 터미널 `Q:`/`A:`. 입력창에 다른 질문 Enter |

---

## 5. 측정값과 결과 가져오기

```bash
# [A]  실행이 끝난 뒤, run_id는 터미널 첫 줄 "Run folder: runs/<run_id>" 또는 ls -t runs | head -1
RUN=$(ls -t runs | head -1)
tools/fetch_server_profile.sh $RUN          # B의 서버 기록을 같은 폴더로 가져옴
python tools/analyze_run.py runs/$RUN       # → runs/$RUN/summary.md, plots/*.png
sed -n 1,30p runs/$RUN/summary.md           # headline: rtt_mean_s, inference_mean_s, overhead_mean_s, request_mb ...
```
```bash
# 로컬 PC
scp -i <pem> -r <user>@<A 공인 IP>:~/carlamayo/runs/<run_id> ./results/
```

---

## 6. 끝낼 때

| 순서 | 어디 | 할 일 |
|---|---|---|
| 1 | [A] | 클라이언트 창에서 `Esc` (영상 저장) |
| 2 | [A] | `tmux attach -t carla` → Ctrl+C |
| 3 | [B] | `tmux attach -t server` → Ctrl+C |
| 4 | AWS 콘솔 | **두 인스턴스 stop** (시간당 과금. open-loop만 할 때는 A만 stop) |

---

## 7. 안 될 때 (자주 겪은 것부터)

| 증상 | 조치 |
|---|---|
| `no inference server at <B_IP>:50051 after 30s` | B 서버가 안 떠 있음. [B] `ss -ltnp \| grep 50051` → 없으면 §3 1번. 있으면 [A] `nc -zv <B_IP> 50051` |
| `nc`가 멈춤(timed out) | B 보안그룹이 A의 22·50051을 안 받음. B 인바운드에 A의 보안그룹 ID 허용 |
| `server is not warmed up` | 모델 로드·워밍업 중. B 로그에 `SERVING`이 뜰 때까지 기다림(첫 실행은 가중치 22 GB 다운로드로 수십 분) |
| B 로그에 `401`/`403` | HF 게이트 미승인 또는 다른 계정. §2 2~3번 |
| `serves Alpamayo '2' but --version '1.5'` / `NUM_FRAMES: client != server` | A·B의 `--version` 또는 커밋 불일치. 둘 다 `git pull` 후 맞춤 |
| pygame 창이 안 뜸 | SSH 터미널에서 실행함. DCV 터미널에서 치거나 `export DISPLAY=:0`, 창 없이 보려면 `--no-pygame-ui` |
| 영상이 없음 | 강제 종료(창 닫기·kill). `Esc`/Ctrl+C로 끝낸다 |
| 주행이 흔들리고 늦게 반응 | `--async`를 썼거나 navigation 지시가 남아 있음. 동기로 돌리고 `\| 1.0` Enter로 지시 해제 |

더 많은 항목: 저장소 `docs/distributed/demo-runbook.md` 부록.

---

## 8. 알아둘 것

- **동기 vs 비동기**: 주행 품질을 보려면 동기(기본), 실시간성·궤적 나이를 보려면 `--async`. 서버는 그대로다.
- **navigation 지시는 지울 때까지 매 추론에 들어간다.** 회전을 마치면 해제하지 않으면 계속 회전하려 한다.
- **VQA는 정지 상태**에서만 답한다(업스트림과 같음).
- 영상 프레임을 메모리에 모았다가 종료 때 쓴다. 1080p 10분 ≈ 6 GB. **2~3분 단위로 끊어 돌린다.**
- 저장소의 runbook·checklist 명령에 적힌 `172.31.38.219`/`172.31.20.213`은 **이전 인스턴스 IP**다. 이 페이지의 `<A_IP>`/`<B_IP>`로 바꿔 친다. 스크립트(`deploy/scripts/*`, `tools/fetch_server_profile.sh`)는 `deploy/hosts.env`를 읽으므로 그대로 된다.
- HF 토큰은 B에만 둔다. gRPC는 VPC 안 평문이며 50051은 외부에 열지 않는다.

---

## 9. 더 보기 (저장소 `main`)

| 문서 | 언제 보나 |
|---|---|
| [README](https://github.com/JwonMoon/carlamayo-my-distributed/blob/main/README.md) | 문서 색인 |
| [porting-guide](https://github.com/JwonMoon/carlamayo-my-distributed/blob/main/docs/distributed/porting-guide.md) | 인스턴스를 처음부터 다시 구성할 때 |
| [demo-runbook](https://github.com/JwonMoon/carlamayo-my-distributed/blob/main/docs/distributed/demo-runbook.md) | 1부: 데모 전체 순서와 기대 출력. 2부: 모든 옵션(open-loop 경로, parity, live-open, 서버 옵션, 공식 노트북) |
| [validation-checklist](https://github.com/JwonMoon/carlamayo-my-distributed/blob/main/docs/distributed/validation-checklist.md) | 단계별 검증 기록 |
| [distributed-architecture](https://github.com/JwonMoon/carlamayo-my-distributed/blob/main/docs/distributed/distributed-architecture.md) | 구조와 데이터 교환이 궁금할 때 |
| [changes-from-upstream](https://github.com/JwonMoon/carlamayo-my-distributed/blob/main/docs/distributed/changes-from-upstream.md) | 원본 대비 무엇을 어디에 왜 바꿨는지 |
| [aveeslab/Carlamayo](https://github.com/aveeslab/Carlamayo) | 원본 오픈소스. 원래 사용법·이슈·업데이트는 여기 |
