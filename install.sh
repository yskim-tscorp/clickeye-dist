#!/bin/sh
# clickeye-daemon 바이너리 + systemd 설치 스크립트 (멱등 — 재실행 = 업그레이드)
#
# 사용법 (콘솔 위저드가 이 형태로 원라이너를 생성한다 — 인터페이스 동결):
#   파이프 실행 (파일을 남기지 않는다 — 기본 권장):
#     curl -fsSL https://raw.githubusercontent.com/yskim-tscorp/clickeye-dist/main/install.sh \
#       | sudo sh -s -- --cloud-url wss://<host>/ws/daemon --token <토큰>
#   파일 실행 (폐쇄망·수동 반입):
#     sudo sh install.sh --cloud-url wss://<host>/ws/daemon --token <토큰> \
#          [--binary ./daemond] [--daemon-id <ID>] [--no-start]
#
# 같은 값을 환경변수로도 받는다 (플래그가 우선):
#   CLICKEYE_CLOUD_URL / CLICKEYE_CLOUD_TOKEN / CLICKEYE_DAEMON_ID
#
# --no-start : 파일 배치까지만 수행 (systemd 없는 환경·CI 검증용)
#
# 하는 일: 전제 검사 → 시스템 사용자/디렉터리 → 바이너리 배치 → env(0600) →
#          systemd 유닛 → enable/restart → localapi 기동 검증(최대 15초).

set -eu

# ---------- 상수 ----------
BIN_DST=/usr/local/bin/daemond
ENV_DIR=/etc/clickeye
ENV_FILE=$ENV_DIR/daemon.env
UNIT_FILE=/etc/systemd/system/clickeye-daemon.service
SERVICE=clickeye-daemon
RUN_USER=clickeye
STATE_DIR=/var/lib/clickeye
STATUS_URL=http://127.0.0.1:58787/api/status
HEALTH_TRIES=15

# ---------- 출력 ----------
info() { printf '[install] %s\n' "$*"; }
warn() { printf '[install] 경고: %s\n' "$*" >&2; }
die()  { printf '[install] 오류: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
사용법: sudo sh install.sh --cloud-url wss://<host>/ws/daemon --token <토큰> \
             [--binary ./daemond] [--daemon-id <ID>] [--no-start]
환경변수로도 지정 가능(플래그 우선): CLICKEYE_CLOUD_URL, CLICKEYE_CLOUD_TOKEN, CLICKEYE_DAEMON_ID
USAGE
}

# 전체 흐름을 main 으로 감싼다 — 파이프 실행(curl | sudo sh)에서 다운로드가 중간에
# 끊기면 본문이 부분 실행되는 사고를 막는다: 정의만 스트리밍되고, 실행은 파일 끝의
# `main "$@"` 한 줄이 온전히 도착했을 때만 시작된다.
main() {

# ---------- 인자 ----------
# 파이프 실행($0=sh)에서는 dirname 이 "." 이 되어 "현재 디렉터리의 daemond" 가 기본이 된다.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

CLOUD_URL=${CLICKEYE_CLOUD_URL:-}
TOKEN=${CLICKEYE_CLOUD_TOKEN:-}
DAEMON_ID=${CLICKEYE_DAEMON_ID:-}
BINARY=''
NO_START=0

while [ $# -gt 0 ]; do
  case $1 in
    --cloud-url)   [ $# -ge 2 ] || die "--cloud-url 뒤에 값이 없습니다"; CLOUD_URL=$2; shift 2 ;;
    --cloud-url=*) CLOUD_URL=${1#--cloud-url=}; shift ;;
    --token)       [ $# -ge 2 ] || die "--token 뒤에 값이 없습니다"; TOKEN=$2; shift 2 ;;
    --token=*)     TOKEN=${1#--token=}; shift ;;
    --binary)      [ $# -ge 2 ] || die "--binary 뒤에 값이 없습니다"; BINARY=$2; shift 2 ;;
    --binary=*)    BINARY=${1#--binary=}; shift ;;
    --daemon-id)   [ $# -ge 2 ] || die "--daemon-id 뒤에 값이 없습니다"; DAEMON_ID=$2; shift 2 ;;
    --daemon-id=*) DAEMON_ID=${1#--daemon-id=}; shift ;;
    --no-start)    NO_START=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "알 수 없는 인자: $1" ;;
  esac
done

# 바이너리 소스 결정 — v1 은 로컬 파일만 지원한다 (기본: 스크립트 옆 ./daemond).
# 유통 채널이 생기면 이 함수에 URL 다운로드(+체크섬 검증) 분기를 추가한다.
resolve_binary() {
  if [ -n "$BINARY" ]; then
    printf '%s\n' "$BINARY"
  else
    printf '%s/daemond\n' "$SCRIPT_DIR"
  fi
}
BIN_SRC=$(resolve_binary)

# ---------- 1. 전제 검사 ----------
[ "$(uname -s)" = "Linux" ] || die "이 스크립트는 Linux 전용입니다 (현재: $(uname -s)). Windows/macOS 는 Docker 설치(가이드 §2)를 쓰세요"
[ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다 — sudo sh install.sh ... 로 실행하세요"

HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  HAS_SYSTEMD=1
fi
if [ "$HAS_SYSTEMD" -eq 0 ]; then
  if [ "$NO_START" -eq 1 ]; then
    warn "systemd 가 감지되지 않았습니다 — 파일 배치만 수행하고 서비스 등록/기동은 건너뜁니다"
  else
    die "systemd 가 필요합니다 (systemctl 미존재 또는 systemd 미부팅). 파일 배치만 하려면 --no-start 를 쓰세요"
  fi
fi

command -v git >/dev/null 2>&1 || die "git 이 없습니다 — 잡 작업공간 provisioning 에 필수입니다. 먼저 설치하세요 (예: apt-get install -y git)"

command -v node >/dev/null 2>&1 || die "Node.js 가 없습니다 — AI CLI 실행 런타임으로 Node.js 22 이상이 필요합니다"
NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
case $NODE_MAJOR in
  ''|*[!0-9]*) die "node -v 출력을 해석할 수 없습니다: '$(node -v 2>&1 || true)'" ;;
esac
[ "$NODE_MAJOR" -ge 22 ] || die "Node.js 22 이상이 필요합니다 (현재: $(node -v))"

command -v claude >/dev/null 2>&1 || \
  warn "claude CLI 가 PATH 에 없습니다 — Claude Code 를 쓰려면 npm install -g @anthropic-ai/claude-code (gemini/codex 등 다른 AI CLI 를 쓴다면 무시해도 된다)"

[ -n "$CLOUD_URL" ] || { usage >&2; die "--cloud-url (또는 CLICKEYE_CLOUD_URL) 이 필요합니다 — Cloud WS 주소 (wss://<host>/ws/daemon)"; }
[ -n "$TOKEN" ]     || { usage >&2; die "--token (또는 CLICKEYE_CLOUD_TOKEN) 이 필요합니다 — 관제 콘솔의 데몬 토큰 화면에서 발급"; }

[ -f "$BIN_SRC" ] || die "데몬 바이너리를 찾을 수 없습니다: $BIN_SRC — 스크립트 옆에 daemond 를 두거나 --binary <경로> 로 지정하세요"
[ -x "$BIN_SRC" ] || warn "$BIN_SRC 에 실행권한이 없습니다 — 설치 시 0755 로 부여합니다"

info "전제 검사 통과 (systemd=$([ "$HAS_SYSTEMD" -eq 1 ] && echo yes || echo no), node=$(node -v))"

# ---------- 2. 배치 (멱등) ----------
# 2-1) 시스템 사용자
if getent passwd "$RUN_USER" >/dev/null 2>&1; then
  info "시스템 사용자 $RUN_USER — 이미 존재 (통과)"
else
  NOLOGIN=$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)
  useradd -r -m -d "$STATE_DIR" -s "$NOLOGIN" "$RUN_USER"
  info "시스템 사용자 $RUN_USER 생성"
fi

# 2-2) 상태 디렉터리
mkdir -p "$STATE_DIR/data" "$STATE_DIR/workspaces"
chown "$RUN_USER:$RUN_USER" "$STATE_DIR" "$STATE_DIR/data" "$STATE_DIR/workspaces"

# 2-3) 바이너리 — 실행 중이면 정지 후 교체 (업그레이드 경로)
if [ "$HAS_SYSTEMD" -eq 1 ] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  info "실행 중인 $SERVICE 정지 (바이너리 교체를 위해)"
  systemctl stop "$SERVICE"
fi
install -m 0755 "$BIN_SRC" "$BIN_DST"
info "바이너리 배치: $BIN_DST"

# 2-4) env 파일 (토큰이 들어간다 — 0600, $RUN_USER 소유. 기존 파일은 백업 후 갱신)
mkdir -p "$ENV_DIR"
if [ -f "$ENV_FILE" ]; then
  BACKUP=$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S).$$
  cp -p "$ENV_FILE" "$BACKUP"
  info "기존 env 백업: $BACKUP"
fi
OLD_UMASK=$(umask)
umask 077
{
  printf 'CLICKEYE_CLOUD_URL=%s\n' "$CLOUD_URL"
  printf 'CLICKEYE_CLOUD_TOKEN=%s\n' "$TOKEN"
  printf 'CLICKEYE_REQUIRE_CLOUD=true\n'
  printf 'CLICKEYE_DATA_DIR=%s\n' "$STATE_DIR/data"
  printf 'CLICKEYE_WORKSPACE_DIR=%s\n' "$STATE_DIR/workspaces"
  if [ -n "$DAEMON_ID" ]; then
    printf 'CLICKEYE_DAEMON_ID=%s\n' "$DAEMON_ID"
  fi
} > "$ENV_FILE.tmp"
umask "$OLD_UMASK"
chown "$RUN_USER:$RUN_USER" "$ENV_FILE.tmp"
chmod 0600 "$ENV_FILE.tmp"
mv -f "$ENV_FILE.tmp" "$ENV_FILE"
info "env 작성: $ENV_FILE (0600, $RUN_USER 소유)"

# 2-5) systemd 유닛 (가이드 §3 유닛과 동일 내용)
cat > "$UNIT_FILE" <<'UNIT'
[Unit]
Description=ClickEye execution daemon
After=network-online.target
Wants=network-online.target

[Service]
User=clickeye
EnvironmentFile=/etc/clickeye/daemon.env
ExecStart=/usr/local/bin/daemond
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
info "systemd 유닛 배치: $UNIT_FILE"

# ---------- 3. 기동 + 검증 ----------
if [ "$NO_START" -eq 1 ]; then
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl daemon-reload
  fi
  info "──────────────────────────────────────────────"
  info "완료 (--no-start): 파일 배치까지 끝났습니다. 기동은:"
  info "  sudo systemctl daemon-reload && sudo systemctl enable --now $SERVICE"
  exit 0
fi

systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
info "$SERVICE enable + (re)start 완료 — localapi 응답 대기"

# 폴링: curl → wget → node fetch 순 폴백
probe() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "$STATUS_URL" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 2 -t 1 -O /dev/null "$STATUS_URL" 2>/dev/null
  else
    node -e "fetch('$STATUS_URL').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null
  fi
}

i=0
while [ "$i" -lt "$HEALTH_TRIES" ]; do
  if probe; then
    info "──────────────────────────────────────────────"
    info "설치 성공: $SERVICE 기동 확인 ($STATUS_URL 응답)"
    info "다음 확인: 관제 콘솔 데몬 목록에 토큰 라벨 이름으로 온라인 표시되는지"
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done

warn "──────────────────────────────────────────────"
warn "설치 실패: $STATUS_URL 이 ${HEALTH_TRIES}초 안에 응답하지 않았습니다"
warn "로그를 확인하세요: journalctl -u $SERVICE -n 20"
warn "(토큰/URL 오류로 인한 fail-closed 기동 거부가 가장 흔한 원인 — 가이드 §7)"
exit 1

}

main "$@"
