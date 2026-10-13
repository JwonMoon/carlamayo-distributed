# Carlamayo 분산 데모 사용 설명서

> 구성이 끝난 인스턴스 두 대를 **받은 사람**을 위한 문서다. 처음 한 번 할 일, 매번 돌리는 순서, 각 단계에서 무엇이 보이면 정상인지를 담는다.
> 옵션 전체와 배경은 §7의 문서들에 있다. `<...>`는 자기 값으로 바꾼다.

| 항목 | 값 |
|---|---|
| 담당자 / 문의 | `<이름, 연락처>` |
| 저장소 | https://github.com/JwonMoon/carlamayo-distributed (`main`, 두 인스턴스 모두 `~/carlamayo`에 클론됨) |
| 인계일 | `<날짜>` |

---

## 1. 개요

**무엇인가**
- CARLA 시뮬레이터(A)와 Alpamayo 1.5 추론 서버(B)를 **서로 다른 EC2 인스턴스**에서 돌리고 gRPC로 연결한 자율주행 데모.
- A의 `carlamayo.py`가 카메라 4장을 1초에 한 번 B로 보내고, B가 돌려준 궤적으로 A의 차가 달린다.

**출처**
- 원본은 오픈소스 [aveeslab/Carlamayo](https://github.com/aveeslab/Carlamayo). NVIDIA Alpamayo를 CARLA에 붙여 돌리는 프로젝트이며 **한 GPU 머신**에서 CARLA와 모델을 함께 돌린다.
- 이 저장소는 그 원본을 포크해 **모델 추론만 B로 분리**했다. 더한 것은 gRPC 서버·원격 어댑터, `--inference-server` 플래그, 실행별 결과 폴더와 측정 도구, 설치·검증 스크립트, 한국어 문서. 데이터 수집·모드·pygame 창은 원본 그대로.
- 바꾼 내역 전체: [changes-from-upstream.md](changes-from-upstream.md).

**이 환경에서 볼 수 있는 것**

| 기능 | 무엇을 보나 |
|---|---|
| closed-loop (동기) | 모델이 운전한다. 카메라 영상 위 빨간 궤적, 차선 유지·교차로 |
| closed-loop (비동기) | 화면이 멈추지 않는 대신 궤적이 왕복 시간만큼 늦다. 실시간성과 "궤적 나이" |
| navigation + CFG | "Turn right in 30m" 같은 자연어 지시를 주행 중 바꿔 넣는다. 가중치로 지시 강도 조절 |
| VQA | 정지한 채 장면에 대해 질문하고 답을 받는다 |
| 궤적 후보 여러 개 | 서버 옵션으로 후보 궤적 N개를 흰 선으로 함께 그린다 |
| open-loop | 녹화 데이터를 재생하며 궤적만 그린다. CARLA 없이 원격 추론 경로 검증 |
| 측정 리포트 | 실행마다 왕복 시간·추론 시간·네트워크 오버헤드·GPU 사용량이 `summary.md`로 남는다 |

---

## 2. 환경 구성

![환경 구성](diagrams/handover-overview.svg)

| | **A: 시뮬레이터 인스턴스** | **B: 추론 인스턴스** |
|---|---|---|
| 역할 | CARLA 서버 + `carlamayo.py`(인터페이스) + pygame 창 | `alpamayo_server.py` + Alpamayo 1.5 모델 |
| 인스턴스 타입 | g5.2xlarge (A10G 24 GB) | g6e.xlarge (L40S 48 GB) |
| 인스턴스 ID | `<i-...>` | `<i-...>` |
| 사설 IP | `<A_IP>` | `<B_IP>` |
| 공인 IP / DNS | `<...>` | `<...>` |
| SSH | `ssh -i <pem> ubuntu@<A 공인 IP>` | `ssh -i <pem> ubuntu@<B 공인 IP>` |
| 화면 | NICE DCV `https://<A 공인 IP>:8443`, 계정 `ubuntu`, 세션 `simulator-session` (`<가상(XFCE) / 콘솔(GNOME)>`) | 없음 |
| OS | Ubuntu `<버전>` | Ubuntu `<버전>` |
| 키페어 | `<이름>.pem` (보관자 `<이름>`) | 같은 pem |

- **B는 서버 하나만 켜 둔다.** 모드 전환(open/closed, 비동기, navigation, CFG, VQA)은 전부 A에서 한다.
- 화면이 필요한 것은 A의 pygame 창 하나뿐이다. CARLA 서버와 B 서버는 화면 없이 돈다.
- 아래 `[A]`/`[B]`는 어느 인스턴스 터미널에서 치는지다. `[A·DCV]`는 DCV 화면 안의 터미널.

---

## 3. 처음 한 번 (약 30분)

| 순서 | 어디 | 할 일 | 확인 |
|---|---|---|---|
| 1 | 로컬 PC | pem 받아 `chmod 400`, A·B에 SSH | 프롬프트가 뜬다 |
| 2 | [B] | `source ~/carlamayo/a_venv/bin/activate && hf auth login` (**본인** Hugging Face 계정) | `hf auth whoami`에 본인 계정 |
| 3 | 브라우저 | https://huggingface.co/nvidia/Alpamayo-1.5-10B 에서 접근 요청. 승인까지 수 시간~수일이라 **미리** | 페이지에 "you have been granted access" |
| 4 | [A], [B] | `cd ~/carlamayo && git pull && cat deploy/hosts.env` | `SIM_HOST_IP=<A_IP>`, `INFERENCE_HOST_IP=<B_IP>` |
| 5 | [B] | `deploy/scripts/verify-inference-host.sh` | 마지막 줄 `== 0 FAIL` |
| 6 | [A] | `deploy/scripts/verify-sim-host.sh` | 마지막 줄 `== 0 FAIL` |

`FAIL` 줄에 조치가 같이 찍힌다. `flash-attn not importable`은 참고 사항이고 동작에는 문제 없다.

---

## 4. 사용법 (매번 이 순서로)

### 4.1 [B] 추론 서버 켜기

```bash
tmux new -s server
cd ~/carlamayo && source a_venv/bin/activate
python alpamayo_server.py --version 1.5 --host <B_IP> --port 50051
# Ctrl+B, D 로 빠져나옴. 다시 보려면 tmux attach -t server
```
**확인** — 로그 마지막 줄 `SERVING Alpamayo 1.5 ... warmed_up=True`. `nvidia-smi`에 약 21~24 GB. 첫 실행은 가중치 22 GB 다운로드로 수십 분.
`401`/`403`이면 §3의 2~3번(게이트).

### 4.2 [A] DCV 화면 접속

```bash
# [A] SSH 터미널
start_dcv            # 세션이 없으면 만들고, 목록을 보여준다 (stop/start 뒤에는 세션이 사라지므로 매번)
```
브라우저에서 `https://<A 공인 IP>:8443` → 인증서 경고는 한 번 수락 → `ubuntu` 로그인 → 바탕화면에서 터미널 열기(상단 패널의 터미널 아이콘, 또는 바탕화면 오른쪽 클릭 → Applications → Terminal Emulator).

**확인** — `start_dcv` 출력에 `Session: 'simulator-session' ... type:virtual`. 브라우저에 바탕화면과 터미널. 그 터미널에서 `echo $DISPLAY`가 `:0`.
Connecting이나 로딩에서 멈추면 §5.

### 4.3 [A] CARLA 서버 켜기

```bash
# [A] SSH 터미널 (화면 없이, 기본)
tmux new -s carla
unset DISPLAY
cd ~/carla && ./CarlaUE4.sh -RenderOffScreen -quality-level=Epic
# Ctrl+B, D
```
시뮬레이터 화면 자체를 보고 싶으면 DCV 터미널에서 `-RenderOffScreen`을 빼고 띄운다. 창이 하나 더 뜨고 GPU를 더 쓴다.

**확인** — 10~20초 뒤 `nvidia-smi`에 `CarlaUE4` 프로세스 약 6 GB. 뜨자마자 `Signal 11`이면 §5.

### 4.4 [A·DCV] closed-loop 주행

```bash
cd ~/carlamayo && source venv-sim/bin/activate && export CARLA_ROOT=~/carla
python carlamayo.py --loop closed --version 1.5 --inference-server <B_IP>:50051 --run-tag sync
```
2~3분 보고 **`Esc`**. 조작: `Ctrl+P` 일시정지/재개, `Esc` 종료.

**확인** — 창에 카메라 영상 + **빨간 궤적**, 아래 패널 `RUNNING | frame N | NN km/h | inference 2.xx s`, 터미널에 `[Frame k] Inference: 2.xx s`가 약 1초마다. 추론하는 동안 화면이 잠깐 멈추는 것이 정상(동기 모드).
`Esc` 뒤 `ls runs/$(ls -t runs | head -1)/`에 `*.mp4`, `log.txt`, `profile_client*.csv`. **창을 강제로 닫으면 영상이 남지 않는다.**

### 4.5 [A·DCV] 모드 바꾸기

`BASE` = `python carlamayo.py --version 1.5 --inference-server <B_IP>:50051`. B는 그대로 둔다(궤적 후보만 예외).

| 모드 | 명령 | 확인 |
|---|---|---|
| 비동기 | `BASE --loop closed --async --run-tag async` | 화면이 안 멈추고 계속 진행. 터미널에 `Trajectory age: N.NN s`. 커브에서 늦게 반응하는 것이 정상 |
| navigation + CFG | `BASE --loop closed --mode navigation --navigation-text "Turn right in 30m" --navigation-weight 1.5 --run-tag nav` | 패널 `Active nav: Turn right in 30m \| weight: 1.50`. 창 입력창에 `Turn left in 20m \| 1.5` Enter → 터미널 `Navigation updated:`. 해제는 `\| 1.0` Enter. **지시는 지울 때까지 매 추론에 들어간다** |
| VQA | `BASE --loop closed --mode vqa --vqa-question "What is ahead?" --run-tag vqa` | 차는 정지. 몇 초 뒤 패널 `Answer:`와 터미널 `A:`. 입력창에 다른 질문 Enter → `VQA question updated:` |
| 궤적 후보 4개 | [B] `tmux attach -t server` → Ctrl+C → 4.1 명령 끝에 `--num-traj-samples 4` → [A·DCV] `BASE --loop closed --run-tag samples4` | 흰 선 4개 + 빨간 선 1개, 터미널 `Selected traj sample: k/3`. **끝나면 B를 옵션 없이 다시 띄운다** |

### 4.6 [A] open-loop (CARLA 없이 추론 경로만)

```bash
# 녹화 데이터가 없을 때만 (CARLA가 떠 있어야 함, 1~2분 뒤 Ctrl+C)
python data_collect.py
# 재생 + 원격 추론
python carlamayo.py --loop open --version 1.5 --data-root carla_data --inference-server <B_IP>:50051 --run-tag remote
```
**확인** — `Run folder: runs/<run_id>`, 프레임마다 `[Frame k] Inference: 2.xx s`, 끝나면 `runs/<run_id>/carla_alpamayo_open_loop_result.mp4`.

### 4.7 [A] 측정값·결과 가져오기

```bash
RUN=$(ls -t runs | head -1)
tools/fetch_server_profile.sh $RUN && python tools/analyze_run.py runs/$RUN
sed -n 1,30p runs/$RUN/summary.md
```
**확인** — headline에 `rtt_mean_s`(왕복), `inference_mean_s`(모델), `overhead_mean_s`(분리 비용), `request_mb`. 그림은 `runs/$RUN/plots/`.
로컬 PC로: `scp -i <pem> -r ubuntu@<A 공인 IP>:~/carlamayo/runs/<run_id> ./results/`

### 4.8 끝내기

| 순서 | 어디 | 할 일 |
|---|---|---|
| 1 | [A·DCV] | 클라이언트 창에서 `Esc` (영상 저장) |
| 2 | [A] | `tmux attach -t carla` → Ctrl+C |
| 3 | [B] | `tmux attach -t server` → Ctrl+C |
| 4 | AWS 콘솔 | **두 인스턴스 stop** (시간당 과금). 다시 start 하면 공인 IP가 바뀔 수 있고 DCV 세션은 4.2로 다시 만든다 |

**한 번에 점검하기** — 어디가 문제인지 모르겠으면: [B] `deploy/scripts/verify-inference-host.sh --serving`, [A] `deploy/scripts/verify-sim-host.sh --link`. 환경·연결·서버를 PASS/FAIL로 보여준다.

---

## 5. 안 될 때

| 증상 | 조치 |
|---|---|
| `no inference server at <B_IP>:50051 after 30s` | B 서버가 안 떠 있음. [B] `ss -ltnp \| grep 50051` → 없으면 4.1. 있으면 [A] `nc -zv <B_IP> 50051` |
| `nc`가 멈춤(timed out) | B 보안그룹이 A의 22·50051을 안 받음. B 인바운드에 A의 보안그룹 ID 허용 |
| `server is not warmed up` | 모델 로드·워밍업 중. B 로그에 `SERVING`이 뜰 때까지 대기 |
| B 로그에 `401`/`403` | 게이트 미승인 또는 다른 계정. §3의 2~3번 |
| `serves Alpamayo '2' but --version '1.5'`, `NUM_FRAMES: client != server` | A·B의 `--version` 또는 커밋 불일치. 양쪽 `git pull` |
| DCV가 Connecting·로딩에서 멈춤 | [A] `dcv list-sessions` 비면 `start_dcv`. 그래도 안 되면 `sudo systemctl status dcvserver`, 보안그룹 8443, 인증서 경고 수락 또는 네이티브 DCV 클라이언트 |
| CARLA가 뜨자마자 `Signal 11` / `Segmentation fault` | 셸의 `DISPLAY`가 없는 X를 가리킴. `unset DISPLAY` 뒤 다시. `~/.bashrc`에 `export DISPLAY`가 있으면 지운다 |
| pygame 창이 안 뜸 | SSH 터미널에서 실행함. DCV 터미널에서 치거나 `export DISPLAY=:0`. 창 없이 보려면 `--no-pygame-ui` |
| 영상이 없음 | 창을 강제로 닫았음. `Esc`/Ctrl+C로 끝낸다 |
| 주행이 흔들리고 늦게 반응 | `--async`이거나 navigation 지시가 남아 있음. 동기로 돌리고 `\| 1.0` Enter로 해제 |

더 많은 항목과 원인 설명: [porting-guide.md](porting-guide.md) §8, [demo-runbook.md](demo-runbook.md) 부록.

---

## 6. 알아둘 것

- **동기 vs 비동기**: 주행 품질은 동기(기본), 실시간성·궤적 나이는 `--async`. 서버는 그대로.
- **navigation 지시는 지울 때까지 매 추론에 들어간다.** 회전이 끝나면 `| 1.0` Enter로 해제.
- **VQA는 정지 상태**에서만 답한다.
- 영상은 메모리에 모았다가 종료 때 쓴다. 1080p 10분 ≈ 6 GB. **2~3분 단위로 끊어 돌린다.**
- `DISPLAY`가 필요한 건 pygame 창뿐. CARLA 서버·B 서버·open-loop·측정은 `DISPLAY` 없이. bashrc에 고정하지 않는다.
- 스크립트(`deploy/scripts/*`, `tools/fetch_server_profile.sh`)는 `deploy/hosts.env`의 주소를 읽는다. 명령줄의 `<B_IP>`는 직접 넣는다.
- HF 토큰은 B에만. gRPC는 VPC 안 평문이며 50051은 외부에 열지 않는다.

---

## 7. 더 보기

| 문서 | 언제 |
|---|---|
| [demo-runbook.md](demo-runbook.md) | 데모 전체 순서와 기대 출력(1부), 모든 옵션·open-loop 경로·parity·live-open·공식 노트북(2부) |
| [porting-guide.md](porting-guide.md) | 인스턴스를 처음부터 다시 구성할 때. 드라이버·DCV·CARLA 바이너리·문제 해결 |
| [validation-checklist.md](validation-checklist.md) | 환경별 검증 기록 |
| [distributed-architecture.md](distributed-architecture.md) | 구조와 데이터 교환 명세 |
| [changes-from-upstream.md](changes-from-upstream.md) | 원본 대비 바꾼 것 |
| [aveeslab/Carlamayo](https://github.com/aveeslab/Carlamayo) | 원본 오픈소스 |
