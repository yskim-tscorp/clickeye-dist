# clickeye-dist

ClickEye 실행 데몬(`daemond`)의 **배포 전용 채널**이다. 소스 저장소는 비공개이며,
여기에는 설치에 필요한 것만 공개된다:

- `install.sh` — 바이너리+systemd 설치 스크립트 (Linux)
- [Releases](../../releases) — 버전별 `daemond-linux-*` 바이너리 + `SHA256SUMS`

## 설치

관제 콘솔의 **데몬 설치** 위저드가 토큰과 접속 주소가 채워진 커맨드를 만들어 준다.
수동으로는:

```bash
curl -fsSL https://raw.githubusercontent.com/yskim-tscorp/clickeye-dist/main/install.sh -o install.sh
sudo sh install.sh --cloud-url wss://<cloud-host>/ws/daemon --token <토큰>
```

폐쇄망은 릴리스에서 바이너리를 받아 반입한 뒤 `--binary ./daemond-linux-amd64` 로 지정한다.

## 무결성

릴리스마다 `SHA256SUMS` 가 함께 올라간다. `install.sh` 는 다운로드한 바이너리를
체크섬으로 검증한 뒤에만 설치한다.
