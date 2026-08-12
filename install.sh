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
# 철거 (계약 종료 시 — 같은 원라이너에 --uninstall 만 바꿔 단다):
#   표준 철거 (잡 이력 데이터는 남긴다):
#     curl -fsSL .../install.sh | sudo sh -s -- --uninstall
#   완전 철거 (잡 이력·시스템 사용자까지 제거):
#     curl -fsSL .../install.sh | sudo sh -s -- --uninstall --purge-data
#
# 하는 일: 전제 검사 → 시스템 사용자/디렉터리 → 바이너리 배치 → env(0600) →
#          systemd 유닛 → enable/restart → localapi 기동 검증(최대 15초).
# 철거가 하는 일: 서비스 stop/disable → 유닛 제거 + daemon-reload → 바이너리 제거 →
#          /etc/clickeye 제거(토큰이 든 env·백업 — 반드시 지운다). 데이터·사용자는
#          기본 보존, --purge-data 에서만 제거.

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
철거:   sudo sh install.sh --uninstall [--purge-data]
        --uninstall   서비스·바이너리·설정(토큰 포함) 제거 — 잡 이력 데이터는 보존
        --purge-data  잡 이력(/var/lib/clickeye)·시스템 사용자까지 제거 (--uninstall 과 함께만)
환경변수로도 지정 가능(플래그 우선): CLICKEYE_CLOUD_URL, CLICKEYE_CLOUD_TOKEN, CLICKEYE_DAEMON_ID
USAGE
}

# ---------- 철거 (--uninstall) ----------
# 멱등 — 이미 없는 것은 경고만 하고 계속한다 (재실행 안전).
# $1 = purge (1 이면 잡 이력 데이터 + 시스템 사용자까지 제거)
do_uninstall() {
  purge=$1

  [ "$(uname -s)" = "Linux" ] || die "이 스크립트는 Linux 전용입니다 (현재: $(uname -s))"
  [ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다 — sudo sh install.sh --uninstall 로 실행하세요"

  HAS_SYSTEMD=0
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    HAS_SYSTEMD=1
  fi
  if [ "$HAS_SYSTEMD" -eq 0 ]; then
    warn "systemd 가 감지되지 않았습니다 — 서비스 정지/해제는 건너뛰고 파일 제거만 수행합니다"
  fi

  if [ "$purge" -eq 1 ]; then
    info "완전 철거(--purge-data) — 표준 철거 대상에 더해 다음을 삭제합니다:"
    info "  - $STATE_DIR (잡 이력 데이터 전체)"
    info "  - 시스템 사용자 $RUN_USER (홈 디렉터리 포함)"
  fi

  # 1) 서비스 정지 + 해제 — 유닛이 있을 때만, 실패해도 계속
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    if [ -f "$UNIT_FILE" ]; then
      systemctl stop "$SERVICE" || warn "$SERVICE 정지 실패 — 계속 진행합니다 (systemctl status $SERVICE 로 확인)"
      systemctl disable "$SERVICE" || warn "$SERVICE 해제 실패 — 계속 진행합니다"
      info "$SERVICE 정지 + 해제"
    else
      warn "systemd 유닛이 이미 없습니다 — 서비스 정지/해제 건너뜀"
    fi
  fi

  # 2) 유닛 파일 제거 + daemon-reload
  if [ -f "$UNIT_FILE" ]; then
    rm -f "$UNIT_FILE"
    info "제거: $UNIT_FILE"
    if [ "$HAS_SYSTEMD" -eq 1 ]; then
      systemctl daemon-reload
    fi
  else
    warn "이미 없음(통과): $UNIT_FILE"
  fi

  # 3) 바이너리 제거
  if [ -f "$BIN_DST" ]; then
    rm -f "$BIN_DST"
    info "제거: $BIN_DST"
  else
    warn "이미 없음(통과): $BIN_DST"
  fi

  # 4) /etc/clickeye 제거 — 토큰이 든 env 와 그 백업들이므로 반드시 지운다
  if [ -d "$ENV_DIR" ]; then
    rm -rf "$ENV_DIR"
    info "제거: $ENV_DIR (토큰이 든 env + 백업 포함)"
  else
    warn "이미 없음(통과): $ENV_DIR"
  fi

  # 5) 잡 이력 데이터 + 시스템 사용자 — 기본 보존, --purge-data 에서만 제거
  if [ "$purge" -eq 1 ]; then
    if [ -d "$STATE_DIR" ]; then
      rm -rf "$STATE_DIR"
      info "제거: $STATE_DIR (잡 이력 데이터)"
    else
      warn "이미 없음(통과): $STATE_DIR"
    fi
    if getent passwd "$RUN_USER" >/dev/null 2>&1; then
      if userdel "$RUN_USER"; then
        info "시스템 사용자 $RUN_USER 삭제"
      else
        warn "사용자 $RUN_USER 삭제 실패 — 해당 사용자의 프로세스가 남아 있는지 확인하세요 (ps -u $RUN_USER)"
      fi
    else
      warn "이미 없음(통과): 시스템 사용자 $RUN_USER"
    fi
    info "──────────────────────────────────────────────"
    info "완전 철거 완료: 서비스·바이너리·설정·데이터·사용자를 모두 제거했습니다"
  else
    info "──────────────────────────────────────────────"
    info "철거 완료: 서비스·바이너리·설정(토큰 포함)을 제거했습니다"
    info "잡 이력 데이터($STATE_DIR)와 시스템 사용자 $RUN_USER 는 남아 있습니다"
    info "완전 제거가 필요하면: --uninstall --purge-data"
  fi
  exit 0
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
UNINSTALL=0
PURGE_DATA=0
INSTALL_ARGS=0  # 설치 전용 플래그가 하나라도 오면 1 — --uninstall 과의 혼용 거부용

while [ $# -gt 0 ]; do
  case $1 in
    --cloud-url)   [ $# -ge 2 ] || die "--cloud-url 뒤에 값이 없습니다"; CLOUD_URL=$2; INSTALL_ARGS=1; shift 2 ;;
    --cloud-url=*) CLOUD_URL=${1#--cloud-url=}; INSTALL_ARGS=1; shift ;;
    --token)       [ $# -ge 2 ] || die "--token 뒤에 값이 없습니다"; TOKEN=$2; INSTALL_ARGS=1; shift 2 ;;
    --token=*)     TOKEN=${1#--token=}; INSTALL_ARGS=1; shift ;;
    --binary)      [ $# -ge 2 ] || die "--binary 뒤에 값이 없습니다"; BINARY=$2; INSTALL_ARGS=1; shift 2 ;;
    --binary=*)    BINARY=${1#--binary=}; INSTALL_ARGS=1; shift ;;
    --daemon-id)   [ $# -ge 2 ] || die "--daemon-id 뒤에 값이 없습니다"; DAEMON_ID=$2; INSTALL_ARGS=1; shift 2 ;;
    --daemon-id=*) DAEMON_ID=${1#--daemon-id=}; INSTALL_ARGS=1; shift ;;
    --no-start)    NO_START=1; INSTALL_ARGS=1; shift ;;
    --uninstall)   UNINSTALL=1; shift ;;
    --purge-data)  PURGE_DATA=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "알 수 없는 인자: $1" ;;
  esac
done

# ---------- 철거 분기 ----------
if [ "$PURGE_DATA" -eq 1 ] && [ "$UNINSTALL" -eq 0 ]; then
  usage >&2
  die "--purge-data 는 --uninstall 과 함께만 쓸 수 있습니다"
fi
if [ "$UNINSTALL" -eq 1 ]; then
  if [ "$INSTALL_ARGS" -eq 1 ]; then
    usage >&2
    die "--uninstall 은 설치 인자(--cloud-url/--token/--binary/--daemon-id/--no-start)와 함께 쓸 수 없습니다"
  fi
  do_uninstall "$PURGE_DATA"
fi

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
