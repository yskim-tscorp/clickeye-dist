# clickeye-dist

ClickEye 실행 데몬(`daemond`)의 **배포 전용 채널**이다. 소스 저장소는 비공개이며,
여기에는 설치에 필요한 것만 공개된다:

- `install.sh` — 바이너리+systemd 설치 스크립트 (Linux, POSIX sh)
- [Releases](../../releases) — 버전별 `daemond-linux-*` 바이너리 + `SHA256SUMS`

## 설치

관제 콘솔의 **데몬 설치** 위저드가 토큰과 접속 주소가 채워진 커맨드를 만들어 준다.
기본 형태는 파이프 실행이다 — 스크립트 파일을 서버에 남기지 않는다:

```bash
curl -fsSL https://raw.githubusercontent.com/yskim-tscorp/clickeye-dist/main/install.sh \
  | sudo sh -s -- --cloud-url wss://<cloud-host>/ws/daemon --token <토큰>
```

스크립트 전체가 `main()` 으로 감싸여 있어 다운로드가 중간에 끊겨도 부분 실행되지 않는다.
바이너리는 Releases 에서 받아 현재 디렉터리에 두거나 `--binary <경로>` 로 지정한다.
폐쇄망은 릴리스 자산을 반입한 뒤 같은 인터페이스로 파일 실행하면 된다.

## 무결성

릴리스마다 `SHA256SUMS` 가 함께 올라간다. 반입한 바이너리는
`sha256sum -c SHA256SUMS` 로 검증한 뒤 설치할 것.
