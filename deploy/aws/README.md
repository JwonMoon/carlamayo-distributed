# AWS 배포 보조 메모

인스턴스 사양·AMI·보안그룹·설치·검증은 [docs/distributed/porting-guide.md](../../docs/distributed/porting-guide.md)에 있다.
여기에는 그 가이드에 없는 세 가지만 둔다. 호스트 주소는 `deploy/hosts.env`(`hosts.env.example` 복사)에 적고 스크립트가 읽는다.

## 1. 보안그룹 권한이 없을 때 관리자에게 보내는 요청 문구

자동 생성된 B의 보안그룹(`launch-wizard-xx` 류)은 보통 사무실 IP만 허용하므로 A→B 접속이
"connection refused"가 아니라 **응답 없이 멈춘다**(패킷이 버려짐). 계정에 보안그룹 편집 권한이 없으면
(콘솔에 `ec2:DescribeSecurityGroupRules 권한이 없습니다`) 아래처럼 요청한다. `<...>`는 자기 값.

> 시뮬레이터 인스턴스 A(`<A 사설 IP>`, `<sg-A>`)에서 추론 인스턴스 B(`<B 사설 IP>`, `<sg-B>`)로
> 내부망 SSH(22)·gRPC(50051) 접속이 필요합니다. B의 보안그룹이 사무실 IP만 허용해 막혀 있습니다.
> (1) B에 sg-A를 추가 연결하거나, (2) sg-B 인바운드에 TCP 22·50051(원본 sg-A)을 추가해
> 주시거나, (3) 제 IAM 사용자에 `ec2:DescribeSecurityGroupRules`, `ec2:DescribeSecurityGroups`,
> `ec2:AuthorizeSecurityGroupIngress`, `ec2:ModifyInstanceAttribute` 권한을 부여해 주세요.
> 모두 VPC 내부 트래픽이며 외부 개방은 없습니다.

(1)에 필요한 권한은 `ec2:ModifyInstanceAttribute`, (2)는 `ec2:AuthorizeSecurityGroupIngress`.
CARLA 포트(2000~2002, 8000)는 어디에도 열지 않는다. gRPC는 평문이므로 VPC 밖으로 노출하지 않는다.

## 2. 추론 서버를 systemd 서비스로 (B, 선택)

`tmux`에서 직접 띄우는 대신 서비스로 등록하면 터미널을 닫아도 유지되고 재부팅·크래시 시 자동으로 다시 뜬다.

```bash
# [B]
sudo cp ~/carlamayo/deploy/systemd/alpamayo-server.service /etc/systemd/system/
sudo nano /etc/systemd/system/alpamayo-server.service   # User=, WorkingDirectory=, ExecStart= 경로와 --host <B 사설 IP>
sudo systemctl daemon-reload
sudo systemctl enable --now alpamayo-server
journalctl -u alpamayo-server -f                        # SERVING ... warmed_up=True 까지 수 분
```

모델 로드 + 워밍업이 수 분 걸리므로 유닛의 `TimeoutStartSec=900`이다. 직접 실행과 서비스는 둘 중 하나만 쓴다.

## 3. 비용

실험이 없을 때는 두 인스턴스를 stop 한다. open-loop만 돌릴 때는 A만 stop 하면 된다.
인스턴스를 stop/start 하면 공인 IP와 DCV 세션이 바뀌거나 사라진다(porting-guide §1.4).
