#!/bin/sh
# clickeye-daemon 설치 스크립트 — **프로젝트당 데몬 하나** (멱등 — 재실행 = 그 프로젝트만 업그레이드)
#
# Docker 는 컨테이너 하나가 프로젝트 하나를 맡는다. 바이너리 설치도 같은 모양으로 맞춘다:
# 프로젝트 설정이 선행되고, 설치 때 --project 를 필수로 받아 프로젝트마다 데몬 하나를 놓는다.
# 스크립트가 환경(사용자·디렉터리·템플릿 유닛)을 먼저 세팅하고 그다음 데몬을 배치한다.
#
# 사용법 (콘솔 위저드가 이 형태로 원라이너를 생성한다 — 인터페이스 동결):
#   파이프 실행 (파일을 남기지 않는다 — 기본 권장):
#     curl -fsSL https://raw.githubusercontent.com/yskim-tscorp/clickeye-dist/main/install.sh \
#       | sudo sh -s -- --project <이름> --cloud-url wss://<host>/ws/daemon --token <토큰>
#   파일 실행 (폐쇄망·수동 반입):
#     sudo sh install.sh --project <이름> --cloud-url wss://<host>/ws/daemon --token <토큰> \
#          [소스옵션] [--daemon-id <ID>] [--no-start]
#
# 설치 소스 3종 — 하나만 지정한다 (여러 개면 거부). **아무것도 안 주는 것이 기본 경로다**:
# 그때는 스크립트 옆 ./daemond 를 먼저 보고, 없으면 공개 배포 채널(clickeye-dist)의 최신
# 릴리스에서 이 호스트 아키텍처에 맞는 바이너리를 받아 SHA256SUMS 로 검증한 뒤 설치한다.
#   --binary <경로>              로컬 바이너리 (지정하면 그 경로만 본다 — 없으면 폴백 없이 중단)
#   --zip <경로|URL>             압축 안의 daemond 를 꺼내 설치. URL 이면 받아서.
#                                --sha256 <값|파일> 이 함께 오면 검증 후에만 설치한다.
#   --git <repo-url> [--git-ref <ref>]
#                                clone 후 go build. **소스 리포는 비공개라 자격증명이 필요하다.**
#
# 같은 값을 환경변수로도 받는다 (플래그가 우선):
#   CLICKEYE_CLOUD_URL / CLICKEYE_CLOUD_TOKEN / CLICKEYE_DAEMON_ID
#
# --no-start : 파일 배치까지만 수행 (systemd 없는 환경·CI 검증용)
#
# 철거 — 프로젝트 단위 (다른 프로젝트는 건드리지 않는다):
#   curl -fsSL .../install.sh | sudo sh -s -- --uninstall --project <이름>
#   curl -fsSL .../install.sh | sudo sh -s -- --uninstall --project <이름> --purge-data
#
# 경로 레이아웃 (프로젝트별로 완전히 분리된다):
#   /opt/clickeye/<project>/daemond          바이너리
#   /opt/clickeye/<project>/{data,workspaces} 데이터·작업공간
#   /etc/clickeye/<project>.env               설정 (0600 — 토큰이 들어간다)
#   /etc/systemd/system/clickeye-daemon@.service  템플릿 유닛 (공용)
#   → 인스턴스 clickeye-daemon@<project>

set -eu

# ---------- 상수 (프로젝트 무관) ----------
BASE_DIR=/opt/clickeye
ENV_DIR=/etc/clickeye
TEMPLATE_UNIT=/etc/systemd/system/clickeye-daemon@.service
UNIT_NAME=clickeye-daemon
RUN_USER=clickeye
HEALTH_TRIES=15

# 구(舊) 단일 인스턴스 레이아웃 — 마이그레이션 안내용으로만 참조한다.
LEGACY_UNIT=/etc/systemd/system/clickeye-daemon.service
LEGACY_BIN=/usr/local/bin/daemond
LEGACY_ENV=/etc/clickeye/daemon.env
LEGACY_STATE=/var/lib/clickeye

# 프로젝트별 localapi 포트 대역 — 한 호스트에 데몬이 여러 개 뜨므로
# 전부 기본 58787 을 물면 두 번째부터 EADDRINUSE 로 죽는다.
PORT_BASE=58800
PORT_SPAN=200

# ---------- 출력 ----------
info() { printf '[install] %s\n' "$*"; }
warn() { printf '[install] 경고: %s\n' "$*" >&2; }
die()  { printf '[install] 오류: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
설치: sudo sh install.sh --project <이름> --cloud-url wss://<host>/ws/daemon --token <토큰> \
           [--binary <경로> | --zip <경로|URL> [--sha256 <값|파일>] | --git <repo-url> [--git-ref <ref>]] \
           [--channel <stable|edge>] [--daemon-id <ID>] [--no-start]

  --project <이름>   필수. 이 호스트에서 데몬을 구분하는 식별자이자 경로·유닛 이름.
                     허용 문자: A-Z a-z 0-9 . _ - (공백·슬래시·'..' 는 거부)
  --binary <경로>    로컬 바이너리. 지정하면 그 경로만 보고, 없으면 중단한다.
                     (소스 옵션을 하나도 주지 않으면: 스크립트 옆 ./daemond → 없으면
                      공개 배포 채널 최신 릴리스를 받아 SHA256SUMS 로 검증 후 설치)
  --zip <경로|URL>   압축 안의 daemond 를 꺼내 설치 (.zip / .tar.gz)
  --sha256 <값|파일> --zip 아카이브의 SHA-256. 없으면 검증을 건너뛴다(경고).
  --git <repo-url>   clone 후 go build (Go 툴체인 필요 / 비공개 리포는 자격증명 필요)
  --git-ref <ref>    --git 과 함께 — 브랜치·태그·커밋
  --channel <이름>   공개 배포 채널에서 받을 때의 채널 (기본: stable)
                     stable — 릴리스된 최신 판.  edge — main 의 최신 빌드(검증 서버용 — 릴리스 전 판이다).
                     소스 옵션(--binary/--zip/--git)과 함께 쓸 수 없다.
  --daemon-id <ID>   데몬 식별자 (기본: <hostname>-<project>)
  --anthropic-key <값>  AI CLI 자격 — env 에 ANTHROPIC_API_KEY 로 기록 (Console 조직 키)
  --oauth-token <값>    AI CLI 자격 — env 에 CLAUDE_CODE_OAUTH_TOKEN 로 기록
  --gh-token <값>       저장소 토큰 — env 에 GH_TOKEN 로 기록 (clone·push·PR)
                        없으면 데몬은 뜨지만 잡이 **마지막 단계(PR 생성)에서** 실패합니다.
                        fine-grained PAT 권장: 대상 저장소 하나에 Contents RW + Pull requests RW.
                        (구독 토큰. 브라우저 있는 호스트에서 claude setup-token 으로 발급)
                        위 둘은 배타이며 **선택**이다 — 없어도 설치는 되고 AI 스텝만 실패한다.
  --no-start         파일 배치까지만 — systemd 없는 환경·CI 검증용

철거: sudo sh install.sh --uninstall --project <이름> [--purge-data]
      --uninstall   그 프로젝트의 서비스·바이너리·설정(토큰 포함)만 제거.
                    다른 프로젝트의 인스턴스는 건드리지 않는다.
      --purge-data  그 프로젝트의 데이터(/opt/clickeye/<이름>)까지 제거.
                    마지막 인스턴스였다면 공용 자원(템플릿 유닛·시스템 사용자)도 정리한다.

환경변수로도 지정 가능(플래그 우선): CLICKEYE_CLOUD_URL, CLICKEYE_CLOUD_TOKEN, CLICKEYE_DAEMON_ID
USAGE
}

# ---------- 프로젝트 이름 검증 ----------
# --project 는 경로(/opt/clickeye/<이름>)와 systemd 인스턴스 이름(clickeye-daemon@<이름>)에
# 그대로 들어간다. 즉 신뢰할 수 없는 값이 파일시스템 경로가 되므로 화이트리스트로 막는다.
validate_project() {
  vp_name=$1
  [ -n "$vp_name" ] || { usage >&2; die "--project <이름> 이 필요합니다 — 프로젝트마다 데몬 하나를 설치합니다"; }
  case $vp_name in
    *[!A-Za-z0-9._-]*)
      die "--project 이름에 쓸 수 없는 문자가 있습니다: '$vp_name' (허용: A-Z a-z 0-9 . _ -)" ;;
  esac
  case $vp_name in
    *..*) die "--project 이름에 '..' 은 쓸 수 없습니다: '$vp_name' (경로 탈출 방지)" ;;
    .*)   die "--project 이름은 '.' 으로 시작할 수 없습니다: '$vp_name'" ;;
    -*)   die "--project 이름은 '-' 으로 시작할 수 없습니다: '$vp_name'" ;;
  esac
  if [ "${#vp_name}" -gt 64 ]; then
    die "--project 이름이 너무 깁니다 (64자 이하): '$vp_name'"
  fi
}

# 프로젝트에 종속된 경로들을 한자리에서 만든다.
set_project_paths() {
  PROJ_DIR=$BASE_DIR/$PROJECT
  BIN_DST=$PROJ_DIR/daemond
  DATA_DIR=$PROJ_DIR/data
  WORK_DIR=$PROJ_DIR/workspaces
  # HOME_DIR — 실행 사용자의 홈. AI CLI 가 자기 설정·상태를 쓸 자리다.
  #
  # 이것이 없으면 `claude -p` 는 **아무 출력도 내지 않고 멈춘다**(실측: exit 124, stdout·
  # stderr 모두 빈 채). 실행 사용자의 홈이 $BASE_DIR(root 소유 0755)이라 쓸 수 없기 때문이다.
  # 잡은 로그 한 줄 없이 타임아웃으로 실패하고, 그 화면에서는 원인을 짚을 방법이 없다.
  # Docker 이미지는 `useradd -m` 이라 홈이 있어 이 경로를 밟지 않는다 — 그래서 두 배포
  # 경로가 갈라져 있었다.
  #
  # 사용자 공용이 아니라 프로젝트별로 두는 이유는 격리다: 한 호스트의 데몬 여럿이 같은
  # CLI 설정·세션 파일을 공유하면 한쪽의 상태가 다른 쪽 잡에 섞인다.
  HOME_DIR=$PROJ_DIR/home
  ENV_FILE=$ENV_DIR/$PROJECT.env
  INSTANCE=$UNIT_NAME@$PROJECT
}

# ---------- systemd 감지 ----------
detect_systemd() {
  HAS_SYSTEMD=0
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    HAS_SYSTEMD=1
  fi
}

# ---------- 남아 있는 다른 인스턴스 개수 ----------
# 공용 자원(템플릿 유닛·시스템 사용자)을 지워도 되는지 판단하는 근거.
# 지금 철거 중인 프로젝트를 제외하고 센다.
count_other_instances() {
  coi_n=0
  for coi_f in "$ENV_DIR"/*.env; do
    [ -f "$coi_f" ] || continue
    if [ "$coi_f" != "$ENV_FILE" ]; then
      coi_n=$((coi_n + 1))
    fi
  done
  for coi_d in "$BASE_DIR"/*/; do
    [ -d "$coi_d" ] || continue
    coi_p=${coi_d%/}
    coi_p=${coi_p##*/}
    if [ "$coi_p" != "$PROJECT" ] && [ -f "$BASE_DIR/$coi_p/daemond" ]; then
      if [ ! -f "$ENV_DIR/$coi_p.env" ]; then
        coi_n=$((coi_n + 1))
      fi
    fi
  done
  printf '%s\n' "$coi_n"
}

# ---------- 철거 (--uninstall --project <이름>) ----------
# 멱등 — 이미 없는 것은 경고만 하고 계속한다 (재실행 안전).
# 멀티 인스턴스 안전 — 이 프로젝트의 인스턴스만 건드린다.
# $1 = purge (1 이면 이 프로젝트의 데이터까지 제거)
do_uninstall() {
  du_purge=$1

  [ "$(uname -s)" = "Linux" ] || die "이 스크립트는 Linux 전용입니다 (현재: $(uname -s))"
  [ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다 — sudo sh install.sh --uninstall --project <이름> 으로 실행하세요"

  detect_systemd
  if [ "$HAS_SYSTEMD" -eq 0 ]; then
    warn "systemd 가 감지되지 않았습니다 — 서비스 정지/해제는 건너뛰고 파일 제거만 수행합니다"
  fi

  info "프로젝트 '$PROJECT' 철거 — 인스턴스 $INSTANCE"
  if [ "$du_purge" -eq 1 ]; then
    info "완전 철거(--purge-data) — 표준 철거 대상에 더해 다음을 삭제합니다:"
    info "  - $PROJ_DIR (이 프로젝트의 잡 이력·작업공간 전체)"
  fi

  # 1) 이 인스턴스만 정지 + 해제
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl stop "$INSTANCE" 2>/dev/null || warn "$INSTANCE 정지 실패(또는 이미 정지) — 계속 진행합니다"
    systemctl disable "$INSTANCE" 2>/dev/null || warn "$INSTANCE 해제 실패(또는 이미 해제) — 계속 진행합니다"
    info "$INSTANCE 정지 + 해제"
  fi

  # 2) env 제거 — 토큰이 든 파일과 그 백업들이므로 반드시 지운다
  du_found=0
  if [ -f "$ENV_FILE" ]; then
    rm -f "$ENV_FILE"
    info "제거: $ENV_FILE (토큰이 든 env)"
    du_found=1
  else
    warn "이미 없음(통과): $ENV_FILE"
  fi
  for du_bak in "$ENV_FILE".bak.*; do
    if [ -f "$du_bak" ]; then
      rm -f "$du_bak"
      info "제거: $du_bak (env 백업)"
    fi
  done

  # 3) 바이너리 제거 (데이터는 남긴다)
  if [ -f "$BIN_DST" ]; then
    rm -f "$BIN_DST"
    info "제거: $BIN_DST"
    du_found=1
  else
    warn "이미 없음(통과): $BIN_DST"
  fi

  # 4) 데이터 — 기본 보존, --purge-data 에서만 제거
  if [ "$du_purge" -eq 1 ]; then
    if [ -d "$PROJ_DIR" ]; then
      rm -rf "$PROJ_DIR"
      info "제거: $PROJ_DIR (잡 이력·작업공간)"
    else
      warn "이미 없음(통과): $PROJ_DIR"
    fi
  fi

  if [ "$du_found" -eq 0 ]; then
    warn "프로젝트 '$PROJECT' 의 설치 흔적을 찾지 못했습니다 — 이미 철거되었거나 이름이 다를 수 있습니다"
    du_list=''
    for du_e in "$ENV_DIR"/*.env; do
      if [ -f "$du_e" ]; then
        du_e=${du_e##*/}
        du_list="$du_list ${du_e%.env}"
      fi
    done
    warn "설치된 프로젝트 목록:${du_list:- (없음)}"
  fi

  # 5) 공용 자원 정리 — **마지막 인스턴스일 때만**.
  #    근거: 템플릿 유닛과 시스템 사용자는 모든 프로젝트가 공유한다. 다른 프로젝트가
  #    남아 있는데 지우면 그 프로젝트가 다음 재시작·재부팅에서 기동 불능이 된다.
  #    따라서 남은 인스턴스가 0 일 때만 정리하고, 그 외에는 명시적으로 보존을 알린다.
  du_others=$(count_other_instances)
  if [ "$du_others" -gt 0 ]; then
    info "다른 프로젝트 인스턴스 ${du_others}개가 남아 있습니다 — 공용 자원(템플릿 유닛·시스템 사용자 $RUN_USER)은 보존합니다"
  else
    if [ -f "$TEMPLATE_UNIT" ]; then
      rm -f "$TEMPLATE_UNIT"
      info "제거: $TEMPLATE_UNIT (마지막 인스턴스였습니다)"
    fi
    if [ -d "$ENV_DIR" ]; then
      rmdir "$ENV_DIR" 2>/dev/null && info "제거: $ENV_DIR (비어 있음)" || true
    fi
    if [ -d "$BASE_DIR" ]; then
      rmdir "$BASE_DIR" 2>/dev/null && info "제거: $BASE_DIR (비어 있음)" || true
    fi
    # 시스템 사용자는 --purge-data 에서만. 데이터 디렉터리 소유자이므로 데이터를
    # 남긴 채 사용자를 지우면 orphan uid 가 남는다.
    if [ "$du_purge" -eq 1 ]; then
      if getent passwd "$RUN_USER" >/dev/null 2>&1; then
        if userdel "$RUN_USER" 2>/dev/null; then
          info "시스템 사용자 $RUN_USER 삭제 (마지막 인스턴스 + --purge-data)"
        else
          warn "사용자 $RUN_USER 삭제 실패 — 해당 사용자의 프로세스가 남아 있는지 확인하세요 (ps -u $RUN_USER)"
        fi
      fi
    else
      info "시스템 사용자 $RUN_USER 와 남은 데이터는 보존합니다 — 완전 제거는 --purge-data"
    fi
  fi

  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl daemon-reload 2>/dev/null || true
  fi

  info "──────────────────────────────────────────────"
  info "철거 완료: 프로젝트 '$PROJECT'"
  exit 0
}

# ---------- 포트 할당 ----------
# 프로젝트 이름에서 결정적으로 뽑고, 다른 프로젝트가 이미 쓰는 값이면 비켜 간다.
derive_port() {
  dp_n=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf '%s\n' "$((PORT_BASE + dp_n % PORT_SPAN))"
}

port_taken_by_other() {
  for pt_f in "$ENV_DIR"/*.env; do
    [ -f "$pt_f" ] || continue
    if [ "$pt_f" = "$ENV_FILE" ]; then
      continue
    fi
    if grep -q "^CLICKEYE_LOCAL_API=127\.0\.0\.1:$1\$" "$pt_f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

alloc_port() {
  # 이 프로젝트에 이미 할당된 포트가 있으면 그대로 재사용한다 — 재실행이 포트를
  # 바꾸면 방화벽·모니터링 설정이 매번 어긋난다(멱등성).
  if [ -f "$ENV_FILE" ]; then
    ap_prev=$(sed -n 's/^CLICKEYE_LOCAL_API=127\.0\.0\.1://p' "$ENV_FILE" 2>/dev/null | head -1)
    case $ap_prev in
      ''|*[!0-9]*) : ;;
      *) printf '%s\n' "$ap_prev"; return 0 ;;
    esac
  fi
  ap_cand=$(derive_port "$PROJECT")
  ap_i=0
  while [ "$ap_i" -lt "$PORT_SPAN" ]; do
    if port_taken_by_other "$ap_cand"; then
      ap_cand=$((ap_cand + 1))
      if [ "$ap_cand" -ge $((PORT_BASE + PORT_SPAN)) ]; then
        ap_cand=$PORT_BASE
      fi
      ap_i=$((ap_i + 1))
    else
      printf '%s\n' "$ap_cand"
      return 0
    fi
  done
  die "localapi 포트 대역($PORT_BASE-$((PORT_BASE + PORT_SPAN - 1)))이 가득 찼습니다 — 쓰지 않는 프로젝트를 철거하세요"
}

# ---------- 소스: 체크섬 ----------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die "sha256sum/shasum 이 없어 체크섬을 검증할 수 없습니다 — coreutils 를 설치하거나 --sha256 을 빼세요"
  fi
}

verify_checksum() {
  vc_file=$1
  vc_expect=$2
  # 값이 아니라 체크섬 '파일'을 준 경우 첫 필드를 꺼낸다 (sha256sum 출력 형식).
  if [ -f "$vc_expect" ]; then
    vc_expect=$(awk 'NR==1{print $1}' "$vc_expect")
  fi
  case $vc_expect in
    *[!A-Fa-f0-9]*|'') die "--sha256 값이 16진수가 아닙니다: '$2'" ;;
  esac
  vc_actual=$(sha256_of "$vc_file")
  # 대소문자 무시 비교
  vc_e=$(printf '%s' "$vc_expect" | tr 'A-F' 'a-f')
  vc_a=$(printf '%s' "$vc_actual" | tr 'A-F' 'a-f')
  if [ "$vc_e" != "$vc_a" ]; then
    die "체크섬 불일치 — 설치를 중단합니다
  기대: $vc_e
  실제: $vc_a
  받은 파일이 손상되었거나 변조되었을 수 있습니다."
  fi
  info "체크섬 검증 통과 (sha256=$vc_a)"
}

download_to() {
  dt_url=$1
  dt_out=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 300 -o "$dt_out" "$dt_url" || die "다운로드 실패: $dt_url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dt_out" "$dt_url" || die "다운로드 실패: $dt_url"
  else
    die "curl/wget 이 없어 URL 을 받을 수 없습니다: $dt_url — 파일로 반입한 뒤 로컬 경로를 주세요"
  fi
  info "다운로드 완료: $dt_url"
}

# ---------- 소스: 공개 배포 채널 (소스 옵션이 없을 때의 기본) ----------
#
# 소스 리포는 비공개이므로 배포 전용 공개 리포가 채널이다(ADR-0011). `latest` 를 쓰는 것은
# 이 스크립트가 이미 멱등하게 "재실행 = 업그레이드"로 설계돼 있기 때문이다 — 특정 버전에
# 고정해야 하는 납품은 그 태그의 자산 URL 을 `--zip` 으로 직접 주면 된다.
DIST_RELEASE_BASE='https://github.com/yskim-tscorp/clickeye-dist/releases/latest/download'
# edge 채널 — main 에 데몬 쪽 변경이 들어올 때마다 다시 만들어지는 사전 릴리스 하나(`edge`). 릴리스 전 판이라
# 기본이 아니다: `--channel edge` 를 준 설치(우리 검증 서버)만 받는다. `latest` 는 사전 릴리스를 가리키지 않는다.
DIST_EDGE_BASE='https://github.com/yskim-tscorp/clickeye-dist/releases/download/edge'

# resolve_release_asset — 이 호스트에 맞는 자산 이름을 RELEASE_ASSET 에 넣는다.
#
# 값을 출력하지 않고 전역에 넣는 이유는 die 다. `x=$(f)` 형태로 부르면 f 안의 die 는
# **서브셸만** 죽이고, 그러면 지원하지 않는 아키텍처에서 빈 이름으로 계속 진행하게 된다.
# set -e 가 결국 잡아 주긴 하지만, 그 사실에 기대는 것과 구조로 막는 것은 다르다.
resolve_release_asset() {
  rra_os=$(uname -s 2>/dev/null || echo unknown)
  if [ "$rra_os" != Linux ]; then
    die "이 스크립트의 자동 다운로드는 Linux 전용입니다 (감지: $rra_os)
  Windows 는 install.ps1 을 쓰세요. 그 밖의 OS 는 바이너리를 반입한 뒤 --binary 로 지정하세요."
  fi
  rra_arch=$(uname -m 2>/dev/null || echo unknown)
  case $rra_arch in
    x86_64|amd64)   RELEASE_ASSET=daemond-linux-amd64 ;;
    aarch64|arm64)  RELEASE_ASSET=daemond-linux-arm64 ;;
    *) die "지원하지 않는 아키텍처입니다: $rra_arch
  배포 채널이 내는 것은 linux amd64/arm64 뿐입니다 — 직접 빌드한 바이너리를 --binary 로 주세요." ;;
  esac
}

# checksum_for — SHA256SUMS 에서 그 자산 한 줄의 해시를 꺼낸다.
#
# 첫 줄을 쓰지 않는 이유는 SHA256SUMS 가 자산 여섯 개를 담기 때문이다 — 첫 줄을 믿으면
# 아키텍처가 다른 순간 "체크섬 불일치"가 뜨고, 그 메시지는 변조를 의심하게 만든다.
# 이름 앞의 `*`(sha256sum 바이너리 모드 표기)는 떼고 비교한다.
checksum_for() {
  awk -v n="$2" '{ f = $2; sub(/^\*/, "", f); if (f == n) { print $1; exit } }' "$1"
}

download_release_binary() {
  drb_out=$1
  resolve_release_asset
  if [ "$CHANNEL" = edge ]; then
    info "설치 소스: 공개 배포 채널 edge — main 의 최신 빌드, 릴리스 전 판입니다 ($RELEASE_ASSET)"
  else
    info "설치 소스: 공개 배포 채널 최신 릴리스 ($RELEASE_ASSET)"
  fi
  download_to "$DIST_RELEASE_BASE/$RELEASE_ASSET" "$drb_out"
  download_to "$DIST_RELEASE_BASE/SHA256SUMS" "$TMP_DIR/SHA256SUMS"
  drb_expect=$(checksum_for "$TMP_DIR/SHA256SUMS" "$RELEASE_ASSET")
  # 검증을 건너뛰지 않는다. --zip 은 사람이 가져온 파일이라 경고 후 진행하지만, 이 경로는
  # 스크립트가 스스로 고른 URL 이므로 대조할 것이 없으면 그것 자체가 이상이다.
  [ -n "$drb_expect" ] || die "SHA256SUMS 에 $RELEASE_ASSET 항목이 없습니다 — 릴리스가 불완전합니다"
  verify_checksum "$drb_out" "$drb_expect"
  # 받은 파일에는 실행권한이 없다. 여기서 주지 않으면 아래 공통 검사가 매번 경고를 띄운다.
  chmod +x "$drb_out" || die "다운로드한 바이너리에 실행권한을 줄 수 없습니다: $drb_out"
}

# ---------- 전제: Agent CLI 자동 설치 ----------
#
# 데몬은 AI 스텝을 CLI 서브프로세스로 실행하므로(steprunner) CLI 가 없으면 잡을 실행할
# 수단이 없다. 예전에는 여기서 설치를 중단하고 `npm install -g` 를 안내했지만, 그러면
# 콘솔 위저드의 원라이너가 "먼저 딴 걸 설치하고 오라"로 끝난다 — 설치 스크립트가 환경을
# 세워 주는 물건인데 이 하나만 사람에게 미루고 있었다.
#
# 방법은 npm 이다. Docker 이미지가 쓰는 것과 같은 물건이어야 두 배포 경로가 어긋나지 않는다.
AGENT_PKG='@anthropic-ai/claude-code'
NODE_MIN=22
NODE_ROOT=/usr/local/lib/nodejs
NODE_DIST='https://nodejs.org/dist/latest-v22.x'

# node_major — 설치된 node 의 메이저 버전. 없거나 해석 불가면 빈 문자열.
node_major() {
  command -v node >/dev/null 2>&1 || return 0
  node -v 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p'
}

# install_node — Node 22 를 공식 배포 tarball 로 설치한다.
#
# 배포판 패키지를 쓰지 않는 이유는 버전이다 — Debian 12·Ubuntu 24.04 모두 Node 18 이라
# CLI 의 engines(>=22)를 못 넘는다. NodeSource 저장소를 붙이는 방법도 있으나 그것은 고객
# 서버의 apt 소스를 우리가 영구히 바꾸는 일이라, 우리 트리 안에 풀고 링크만 거는 쪽을 골랐다.
# 되돌리려면 그 디렉터리와 링크만 지우면 된다.
install_node() {
  case $(uname -m) in
    x86_64|amd64)  in_arch=x64 ;;
    aarch64|arm64) in_arch=arm64 ;;
    *) die "지원하지 않는 아키텍처라 Node 를 자동 설치할 수 없습니다: $(uname -m) — Node $NODE_MIN+ 를 직접 설치한 뒤 다시 실행하세요" ;;
  esac
  command -v tar >/dev/null 2>&1 || die "tar 가 없어 Node 를 설치할 수 없습니다 — tar 를 설치하거나 Node $NODE_MIN+ 를 직접 설치하세요"

  in_tmp=$(mktemp -d 2>/dev/null || mktemp -d -t clickeye-node)
  # 버전을 스크립트에 박지 않는다. SHASUMS256.txt 한 장에서 파일 이름과 체크섬을 함께
  # 얻으므로, 최신 22.x 가 올라가도 이 스크립트는 고칠 것이 없고 검증도 공짜로 따라온다.
  download_to "$NODE_DIST/SHASUMS256.txt" "$in_tmp/SHASUMS256.txt"
  in_file=$(awk -v s="linux-$in_arch.tar.gz" '$2 ~ ("^node-v22\\..*-" s "$") { print $2; exit }' "$in_tmp/SHASUMS256.txt")
  if [ -z "$in_file" ]; then
    rm -rf "$in_tmp"
    die "Node 배포 목록에서 linux-$in_arch 자산을 찾지 못했습니다 — $NODE_DIST/SHASUMS256.txt 를 확인하세요"
  fi
  in_hash=$(awk -v f="$in_file" '$2 == f { print $1; exit }' "$in_tmp/SHASUMS256.txt")

  info "Node.js 설치: $in_file"
  download_to "$NODE_DIST/$in_file" "$in_tmp/$in_file"
  verify_checksum "$in_tmp/$in_file" "$in_hash"

  mkdir -p "$NODE_ROOT"
  tar -xzf "$in_tmp/$in_file" -C "$NODE_ROOT" || { rm -rf "$in_tmp"; die "Node 아카이브 해제 실패"; }
  in_dir=$NODE_ROOT/$(printf '%s' "$in_file" | sed 's/\.tar\.gz$//')
  rm -rf "$in_tmp"
  [ -x "$in_dir/bin/node" ] || die "Node 아카이브 구조가 예상과 다릅니다: $in_dir/bin/node 가 없습니다"
  # /usr/local/bin 에 링크한다 — 데몬은 clickeye 사용자로 돌고 그 PATH 에 있어야 한다.
  for in_b in node npm npx; do
    ln -sf "$in_dir/bin/$in_b" "/usr/local/bin/$in_b"
  done
  info "Node.js 설치 완료: $(node -v 2>/dev/null || echo unknown) ($in_dir)"
}

install_agent_cli() {
  ia_major=$(node_major)
  if [ -z "$ia_major" ]; then
    install_node
  else
    case $ia_major in
      ''|*[!0-9]*) die "node -v 출력을 해석할 수 없습니다 — Node $NODE_MIN+ 를 직접 확인하세요" ;;
    esac
    if [ "$ia_major" -lt "$NODE_MIN" ]; then
      # 이미 있는 Node 를 갈아치우지 않는다. 이 호스트의 다른 프로그램이 그 버전에 매여
      # 있을 수 있고, 설치 스크립트가 조용히 바꿔 놓으면 그쪽이 깨진 이유를 여기서 찾을 수 없다.
      die "Node.js $ia_major 가 설치돼 있지만 Agent CLI 는 $NODE_MIN 이상이 필요합니다.
  이 스크립트는 이미 있는 Node 를 교체하지 않습니다 — 이 호스트의 다른 프로그램이 그 버전에
  매여 있을 수 있습니다. Node 를 올린 뒤 다시 실행하거나, CLI 를 먼저 설치하세요:
    npm install -g $AGENT_PKG"
    fi
  fi
  command -v npm >/dev/null 2>&1 || die "npm 이 없습니다 — Node 설치가 온전하지 않습니다"

  ia_log=$(mktemp 2>/dev/null || mktemp -t clickeye-npm)
  info "Agent CLI 설치: npm install -g $AGENT_PKG"
  # --prefix /usr/local — 전역 설치 자리를 명시한다. node 를 우리 트리에 풀었을 때 npm 의
  # 기본 prefix 는 그 트리 안이 되고, 그러면 claude 가 /usr/local/bin 에 안 놓여
  # 데몬 사용자의 PATH 에서 사라진다.
  if ! npm install -g --prefix /usr/local "$AGENT_PKG" >"$ia_log" 2>&1; then
    tail -20 "$ia_log" >&2
    rm -f "$ia_log"
    die "Agent CLI 설치 실패 — 위 npm 출력을 확인하세요"
  fi
  rm -f "$ia_log"
  command -v claude >/dev/null 2>&1 || die "설치는 끝났는데 claude 가 PATH 에 없습니다 — /usr/local/bin 이 PATH 에 있는지 확인하세요"
  info "Agent CLI 설치 완료: $(claude --version 2>/dev/null || echo unknown)"
}

# ---------- 소스: zip/tar 에서 daemond 꺼내기 ----------
extract_daemond() {
  ed_archive=$1
  ed_dest=$2
  case $ed_archive in
    *.tar.gz|*.tgz|*.tar)
      command -v tar >/dev/null 2>&1 || die "tar 가 없습니다 — 아카이브를 풀 수 없습니다"
      tar -xf "$ed_archive" -C "$TMP_DIR/x" || die "아카이브 해제 실패: $ed_archive"
      ;;
    *)
      command -v unzip >/dev/null 2>&1 || \
        die "unzip 이 없습니다 — --zip 을 쓰려면 설치하세요 (예: apt-get install -y unzip)"
      unzip -qo "$ed_archive" -d "$TMP_DIR/x" || die "압축 해제 실패: $ed_archive"
      ;;
  esac
  # 아카이브 안 어디에 있든 daemond 를 찾는다 (루트/하위 디렉터리 모두 허용).
  ed_found=$(find "$TMP_DIR/x" -type f -name daemond 2>/dev/null | head -1)
  [ -n "$ed_found" ] || die "아카이브 안에서 'daemond' 를 찾지 못했습니다: $ed_archive"
  cp "$ed_found" "$ed_dest"
  chmod 0755 "$ed_dest"
  info "아카이브에서 추출: $ed_found"
}

# ---------- 소스: git clone + go build ----------
build_from_git() {
  bg_dest=$1
  command -v git >/dev/null 2>&1 || \
    die "git 이 없습니다 — --git 은 소스를 clone 해 빌드하는 경로입니다. 먼저 설치하세요 (예: apt-get install -y git)"
  command -v go >/dev/null 2>&1 || \
    die "Go 툴체인이 없습니다 — --git 은 소스에서 go build 로 만듭니다. Go 를 설치하거나 --binary/--zip 을 쓰세요"

  info "소스 빌드: $GIT_URL${GIT_REF:+ (ref: $GIT_REF)}"
  info "  참고: 소스 리포는 비공개입니다 — 이 호스트에 읽기 권한이 있는 자격증명이 있어야 합니다"
  info "  (SSH 배포키 / credential helper / URL 에 포함된 토큰 중 하나)"
  # 비대화식 — 자격증명이 없으면 암호 프롬프트에서 멈추지 말고 즉시 실패해야 한다.
  GIT_TERMINAL_PROMPT=0
  export GIT_TERMINAL_PROMPT
  if [ -n "$GIT_REF" ]; then
    git clone --depth 1 --branch "$GIT_REF" "$GIT_URL" "$TMP_DIR/src" 2>"$TMP_DIR/git.err" && bg_cloned=1 || bg_cloned=0
  else
    git clone --depth 1 "$GIT_URL" "$TMP_DIR/src" 2>"$TMP_DIR/git.err" && bg_cloned=1 || bg_cloned=0
  fi
  if [ "$bg_cloned" -eq 0 ]; then
    # ref 가 커밋 SHA 면 --branch 로는 못 잡는다 — 전체 clone 후 checkout 으로 재시도.
    if [ -n "$GIT_REF" ]; then
      rm -rf "$TMP_DIR/src"
      git clone "$GIT_URL" "$TMP_DIR/src" 2>>"$TMP_DIR/git.err" || {
        sed 's/^/  git| /' "$TMP_DIR/git.err" >&2
        die "clone 실패 — 비공개 리포입니다. 자격증명(SSH 키·토큰)을 확인하세요: $GIT_URL"
      }
      git -C "$TMP_DIR/src" checkout --detach "$GIT_REF" 2>>"$TMP_DIR/git.err" || {
        sed 's/^/  git| /' "$TMP_DIR/git.err" >&2
        die "ref 체크아웃 실패: $GIT_REF"
      }
    else
      sed 's/^/  git| /' "$TMP_DIR/git.err" >&2
      die "clone 실패 — 비공개 리포입니다. 자격증명(SSH 키·토큰)을 확인하세요: $GIT_URL"
    fi
  fi

  # 데몬 모듈 위치 — 모노레포(daemon/) 와 단독 리포 양쪽을 지원한다.
  bg_mod=$TMP_DIR/src
  if [ -d "$TMP_DIR/src/daemon/cmd/daemond" ]; then
    bg_mod=$TMP_DIR/src/daemon
  elif [ ! -d "$TMP_DIR/src/cmd/daemond" ]; then
    die "리포에서 cmd/daemond 를 찾지 못했습니다 — --git 대상이 데몬 소스인지 확인하세요"
  fi

  info "go build 시작 (수 분 걸릴 수 있습니다)"
  ( cd "$bg_mod" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$bg_dest" ./cmd/daemond ) \
    || die "go build 실패 — 위 컴파일 오류를 확인하세요"
  chmod 0755 "$bg_dest"
  info "빌드 완료: $bg_dest"
}

# 전체 흐름을 main 으로 감싼다 — 파이프 실행(curl | sudo sh)에서 다운로드가 중간에
# 끊기면 본문이 부분 실행되는 사고를 막는다: 정의만 스트리밍되고, 실행은 파일 끝의
# `main "$@"` 한 줄이 온전히 도착했을 때만 시작된다.
main() {

# ---------- 인자 ----------
# 파이프 실행($0=sh)에서는 dirname 이 "." 이 되어 "현재 디렉터리의 daemond" 가 기본이 된다.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

PROJECT=''
CLOUD_URL=${CLICKEYE_CLOUD_URL:-}
TOKEN=${CLICKEYE_CLOUD_TOKEN:-}
DAEMON_ID=${CLICKEYE_DAEMON_ID:-}

# AI CLI 자격 — 둘은 배타이며 **선택**이다. 없이 설치해도 데몬은 뜨고 AI 스텝만 죽는다
# (가이드 §1.3 — `Not logged in · Please run /login`).
#
# CLICKEYE_* 와 달리 **환경변수 폴백을 두지 않는다.** 두 가지 이유다: sudo 는 기본적으로
# 환경을 씻으므로(env_reset) 폴백이 거의 발동하지 않아 있으나 마나이고, 발동하는 드문
# 경우에는 설치를 실행한 사람의 개인 키가 고객서버 env 파일에 조용히 굳는다.
# 자격은 명시적으로 건네는 값이어야 한다.
ANTHROPIC_KEY=''
OAUTH_TOKEN=''
GH_TOKEN_VALUE=''
CRED_COUNT=0    # 자격 플래그 개수 — 2 면 거부

BINARY=''
ZIP_SRC=''
SHA256=''
GIT_URL=''
GIT_REF=''
NO_START=0
UNINSTALL=0
PURGE_DATA=0
INSTALL_ARGS=0  # 설치 전용 플래그가 하나라도 오면 1 — --uninstall 과의 혼용 거부용
SRC_COUNT=0     # 소스 옵션 개수 — 2 이상이면 거부
SRC_KIND=binary
CHANNEL=stable
CHANNEL_SET=0

while [ $# -gt 0 ]; do
  case $1 in
    --project)     [ $# -ge 2 ] || die "--project 뒤에 값이 없습니다"; PROJECT=$2; shift 2 ;;
    --project=*)   PROJECT=${1#--project=}; shift ;;
    --cloud-url)   [ $# -ge 2 ] || die "--cloud-url 뒤에 값이 없습니다"; CLOUD_URL=$2; INSTALL_ARGS=1; shift 2 ;;
    --cloud-url=*) CLOUD_URL=${1#--cloud-url=}; INSTALL_ARGS=1; shift ;;
    --token)       [ $# -ge 2 ] || die "--token 뒤에 값이 없습니다"; TOKEN=$2; INSTALL_ARGS=1; shift 2 ;;
    --token=*)     TOKEN=${1#--token=}; INSTALL_ARGS=1; shift ;;
    --binary)      [ $# -ge 2 ] || die "--binary 뒤에 값이 없습니다"; BINARY=$2; SRC_KIND=binary; SRC_COUNT=$((SRC_COUNT + 1)); INSTALL_ARGS=1; shift 2 ;;
    --binary=*)    BINARY=${1#--binary=}; SRC_KIND=binary; SRC_COUNT=$((SRC_COUNT + 1)); INSTALL_ARGS=1; shift ;;
    --zip)         [ $# -ge 2 ] || die "--zip 뒤에 값이 없습니다"; ZIP_SRC=$2; SRC_KIND=zip; SRC_COUNT=$((SRC_COUNT + 1)); INSTALL_ARGS=1; shift 2 ;;
    --zip=*)       ZIP_SRC=${1#--zip=}; SRC_KIND=zip; SRC_COUNT=$((SRC_COUNT + 1)); INSTALL_ARGS=1; shift ;;
    --sha256)      [ $# -ge 2 ] || die "--sha256 뒤에 값이 없습니다"; SHA256=$2; INSTALL_ARGS=1; shift 2 ;;
    --sha256=*)    SHA256=${1#--sha256=}; INSTALL_ARGS=1; shift ;;
    --git)         [ $# -ge 2 ] || die "--git 뒤에 값이 없습니다"; GIT_URL=$2; SRC_KIND=git; SRC_COUNT=$((SRC_COUNT + 1)); INSTALL_ARGS=1; shift 2 ;;
    --git=*)       GIT_URL=${1#--git=}; SRC_KIND=git; SRC_COUNT=$((SRC_COUNT + 1)); INSTALL_ARGS=1; shift ;;
    --git-ref)     [ $# -ge 2 ] || die "--git-ref 뒤에 값이 없습니다"; GIT_REF=$2; INSTALL_ARGS=1; shift 2 ;;
    --git-ref=*)   GIT_REF=${1#--git-ref=}; INSTALL_ARGS=1; shift ;;
    --channel)     [ $# -ge 2 ] || die "--channel 뒤에 값이 없습니다"; CHANNEL=$2; CHANNEL_SET=1; INSTALL_ARGS=1; shift 2 ;;
    --channel=*)   CHANNEL=${1#--channel=}; CHANNEL_SET=1; INSTALL_ARGS=1; shift ;;
    --daemon-id)   [ $# -ge 2 ] || die "--daemon-id 뒤에 값이 없습니다"; DAEMON_ID=$2; INSTALL_ARGS=1; shift 2 ;;
    --daemon-id=*) DAEMON_ID=${1#--daemon-id=}; INSTALL_ARGS=1; shift ;;
    --anthropic-key)   [ $# -ge 2 ] || die "--anthropic-key 뒤에 값이 없습니다"; ANTHROPIC_KEY=$2; CRED_COUNT=$((CRED_COUNT + 1)); INSTALL_ARGS=1; shift 2 ;;
    --anthropic-key=*) ANTHROPIC_KEY=${1#--anthropic-key=}; CRED_COUNT=$((CRED_COUNT + 1)); INSTALL_ARGS=1; shift ;;
    --oauth-token)     [ $# -ge 2 ] || die "--oauth-token 뒤에 값이 없습니다"; OAUTH_TOKEN=$2; CRED_COUNT=$((CRED_COUNT + 1)); INSTALL_ARGS=1; shift 2 ;;
    --oauth-token=*)   OAUTH_TOKEN=${1#--oauth-token=}; CRED_COUNT=$((CRED_COUNT + 1)); INSTALL_ARGS=1; shift ;;
    # 저장소 토큰은 CRED_COUNT 에 넣지 않는다 — AI 자격과 배타적이지 않고, 둘 다 필요하다.
    --gh-token)        [ $# -ge 2 ] || die "--gh-token 뒤에 값이 없습니다"; GH_TOKEN_VALUE=$2; INSTALL_ARGS=1; shift 2 ;;
    --gh-token=*)      GH_TOKEN_VALUE=${1#--gh-token=}; INSTALL_ARGS=1; shift ;;
    --no-start)    NO_START=1; INSTALL_ARGS=1; shift ;;
    --uninstall)   UNINSTALL=1; shift ;;
    --purge-data)  PURGE_DATA=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "알 수 없는 인자: $1" ;;
  esac
done

# ---------- 프로젝트 (설치·철거 공통 필수) ----------
validate_project "$PROJECT"
set_project_paths

# ---------- 철거 분기 ----------
if [ "$PURGE_DATA" -eq 1 ] && [ "$UNINSTALL" -eq 0 ]; then
  usage >&2
  die "--purge-data 는 --uninstall 과 함께만 쓸 수 있습니다"
fi
if [ "$UNINSTALL" -eq 1 ]; then
  if [ "$INSTALL_ARGS" -eq 1 ]; then
    usage >&2
    die "--uninstall 은 설치 인자(--cloud-url/--token/--binary/--zip/--git/--daemon-id/--no-start)와 함께 쓸 수 없습니다"
  fi
  do_uninstall "$PURGE_DATA"
fi

# ---------- 소스 옵션 배타 검사 ----------
if [ "$SRC_COUNT" -gt 1 ]; then
  usage >&2
  die "설치 소스는 하나만 지정하세요 — --binary / --zip / --git 중 택 1 (지정된 개수: $SRC_COUNT)"
fi
# 채널은 「공개 배포 채널에서 받을 때」만 뜻이 있다 — 소스를 직접 준 설치에 붙이면 어느 쪽이 설치됐는지 흐려진다.
case $CHANNEL in
  stable) ;;
  edge)   DIST_RELEASE_BASE=$DIST_EDGE_BASE ;;
  *)      usage >&2; die "--channel 은 stable 또는 edge 입니다 (받은 값: $CHANNEL)" ;;
esac
if [ "$CHANNEL_SET" -eq 1 ] && [ "$SRC_COUNT" -gt 0 ]; then
  die "--channel 은 소스 옵션(--binary/--zip/--git)과 함께 쓸 수 없습니다 — 채널은 공개 배포 채널에서 받을 때만 고릅니다"
fi
if [ -n "$SHA256" ] && [ "$SRC_KIND" != zip ]; then
  die "--sha256 은 --zip 과 함께만 쓸 수 있습니다"
fi
if [ "$CRED_COUNT" -gt 1 ]; then
  usage >&2
  die "AI CLI 자격은 하나만 지정하세요 — --anthropic-key 와 --oauth-token 은 함께 쓸 수 없습니다"
fi
if [ -n "$GIT_REF" ] && [ "$SRC_KIND" != git ]; then
  die "--git-ref 는 --git 과 함께만 쓸 수 있습니다"
fi

# ---------- 필수 인자·접속 주소 ----------
# 도구 설치(Node·Agent CLI)보다 **먼저** 본다 — 주소가 틀렸다는 것을 몇 분 걸리는 설치가 끝난 뒤에 알게 하지 않는다.
[ -n "$CLOUD_URL" ] || { usage >&2; die "--cloud-url (또는 CLICKEYE_CLOUD_URL) 이 필요합니다 — Cloud WS 주소 (wss://<host>/ws/daemon)"; }
[ -n "$TOKEN" ]     || { usage >&2; die "--token (또는 CLICKEYE_CLOUD_TOKEN) 이 필요합니다 — 관제 콘솔의 데몬 토큰 화면에서 발급"; }

# 접속 주소 점검 — 「설치는 됐는데 붙지 않는다」의 대부분이 주소다(2026-11-11 실측). 막지 않고 **설치할 때 말한다**:
# 주소가 맞는지는 이 호스트의 사정이라 스크립트가 단정할 수 없다. 인터페이스는 그대로다(새 플래그 없음).
#
#   - 자리표시자(<...>)가 남았으면 중단 — 그대로는 절대 붙지 않는다.
#   - 스킴이 ws/wss 가 아니면 중단.
#   - localhost·127.x·host.docker.internal — 이 호스트 자신을 가리킨다. 관제 서버가 다른 PC 에 있으면 붙지 않는다.
#   - 평문 ws:// 로 다른 호스트 — 데몬은 기본으로 거부한다(토큰과 자격이 평문으로 지나간다). 여기서 허용 스위치를
#     env 에 적어 주고 경고한다. 원하지 않으면 wss:// 주소로 다시 설치한다.
INSECURE_WS=0
case $CLOUD_URL in
  *'<'*|*'>'*) die "--cloud-url 에 자리표시자가 남아 있습니다: $CLOUD_URL — <backend-host> 를 관제 서버의 실제 주소로 바꾸세요" ;;
esac
case $CLOUD_URL in
  ws://*|wss://*|WS://*|WSS://*) ;;
  *) die "--cloud-url 은 ws:// 또는 wss:// 로 시작해야 합니다: $CLOUD_URL (예: wss://<host>/ws/daemon)" ;;
esac
WS_HOST=${CLOUD_URL#*://}
WS_HOST=${WS_HOST%%/*}
case $WS_HOST in
  \[*) WS_HOST=${WS_HOST#\[}; WS_HOST=${WS_HOST%%\]*} ;;
  *)   WS_HOST=${WS_HOST%%:*} ;;
esac
case $WS_HOST in
  localhost|127.*|::1)
    warn "접속 주소가 이 호스트 자신($WS_HOST)을 가리킵니다 — 관제 서버가 이 호스트에 떠 있을 때만 붙습니다. 다른 PC 에 있으면 그 PC 의 주소로 다시 설치하세요" ;;
  host.docker.internal)
    warn "host.docker.internal 은 Docker 컨테이너 안에서만 풀리는 이름입니다 — 이 설치(systemd)에서는 이름 풀이에 실패할 수 있습니다. 관제 서버의 실제 주소(이름이나 IP)를 쓰세요" ;;
  *)
    case $CLOUD_URL in
      ws://*|WS://*)
        INSECURE_WS=1
        warn "평문 ws:// 로 다른 호스트($WS_HOST)에 붙습니다 — 데몬 토큰과 내려오는 자격·명령이 암호화 없이 지나갑니다"
        warn "신뢰하는 내부망으로 보고 허용 스위치(CLICKEYE_ALLOW_INSECURE_WS=1)를 env 에 적습니다. 원하지 않으면 wss:// 주소로 다시 설치하세요" ;;
    esac ;;
esac
case $CLOUD_URL in
  */ws/daemon|*/ws/daemon/) ;;
  *) warn "접속 주소가 /ws/daemon 으로 끝나지 않습니다: $CLOUD_URL — 리버스 프록시가 다른 경로에 걸어 둔 것이 아니면 404 로 붙지 않습니다" ;;
esac

# ---------- 1. 전제 검사 ----------
[ "$(uname -s)" = "Linux" ] || die "이 스크립트는 Linux 전용입니다 (현재: $(uname -s)). Windows/macOS 는 Docker 설치(가이드 §2)를 쓰세요"
[ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다 — sudo sh install.sh ... 로 실행하세요"

detect_systemd
if [ "$HAS_SYSTEMD" -eq 0 ]; then
  if [ "$NO_START" -eq 1 ]; then
    warn "systemd 가 감지되지 않았습니다 — 파일 배치만 수행하고 서비스 등록/기동은 건너뜁니다"
  else
    die "systemd 가 필요합니다 (systemctl 미존재 또는 systemd 미부팅). 파일 배치만 하려면 --no-start 를 쓰세요"
  fi
fi

# Agent CLI — claude 또는 codex 중 최소 하나. 둘 다 없으면 잡을 실행할 수단이 없다.
AGENT_CLIS=''
if command -v claude >/dev/null 2>&1; then
  AGENT_CLIS=claude
fi
if command -v codex >/dev/null 2>&1; then
  if [ -n "$AGENT_CLIS" ]; then AGENT_CLIS="$AGENT_CLIS, codex"; else AGENT_CLIS=codex; fi
fi
if [ -z "$AGENT_CLIS" ]; then
  info "Agent CLI 가 없습니다 — 설치합니다 (claude)"
  install_agent_cli
  AGENT_CLIS=claude
fi

# git·Node 는 **기동 차단 사유가 아니다**(경고로 낮춘다).
# 근거: 무엇이 빠졌는지는 데몬이 접속 시 관제로 올려(daemon.hello.env) 콘솔이 한자리에서
# 보여준다. 설치 시점에 호스트마다 막아 세우는 것보다, 일단 붙여 놓고 콘솔에서
# 환경 미비를 한눈에 확인·보강하는 편이 운영 부담이 낮다.
if ! command -v git >/dev/null 2>&1; then
  warn "git 이 없습니다 — 잡 작업공간 provisioning 이 실패합니다. 설치를 계속하되 보강하세요 (apt-get install -y git)"
  warn "  (부재 사실은 데몬이 접속 시 관제 콘솔에 환경 리포트로 올립니다)"
fi
# gh — 작업의 결과(PR)를 만들고 콘솔 머지를 집행하는 도구다. clone·push 는 gh 없이도 저장소 토큰으로 되지만(데몬이 git 에
# 직접 잇는다), PR 생성은 gh 뿐이다 — 없으면 작업이 AI 단계를 다 돌린 뒤 맨 끝에서 실패한다. 로컬 저장소 모드만 쓰면 필요 없다.
if ! command -v gh >/dev/null 2>&1; then
  warn "gh(GitHub CLI)가 없습니다 — 작업이 맨 끝(PR 생성)에서 실패하고 콘솔 머지도 되지 않습니다. 설치를 계속하되 보강하세요"
  warn "  (https://github.com/cli/cli#installation — 부재 사실은 콘솔 데몬 카드의 「저장소 쓰기」에도 보입니다)"
fi
if ! command -v node >/dev/null 2>&1; then
  warn "Node.js 가 없습니다 — Node 기반 AI CLI 실행에 필요합니다(권장 22+). 설치를 계속하되 보강하세요"
  warn "  (부재 사실은 데몬이 접속 시 관제 콘솔에 환경 리포트로 올립니다)"
  NODE_DESC=none
else
  NODE_DESC=$(node -v 2>/dev/null || echo unknown)
  NODE_MAJOR=$(printf '%s' "$NODE_DESC" | sed 's/^v//' | cut -d. -f1)
  case $NODE_MAJOR in
    ''|*[!0-9]*) warn "node -v 출력을 해석할 수 없습니다: '$NODE_DESC'" ;;
    *) if [ "$NODE_MAJOR" -lt 22 ]; then
         warn "Node.js 22 이상을 권장합니다 (현재: $NODE_DESC) — 설치는 계속합니다"
       fi ;;
  esac
fi


# 구 단일 인스턴스 설치가 남아 있으면 알린다 (자동 이관은 하지 않는다).
if [ -f "$LEGACY_UNIT" ] || [ -f "$LEGACY_BIN" ]; then
  warn "──────────────────────────────────────────────"
  warn "구(舊) 단일 인스턴스 설치가 이 호스트에 남아 있습니다:"
  warn "  $LEGACY_UNIT / $LEGACY_BIN / $LEGACY_ENV"
  warn "새 설치는 프로젝트 단위($PROJ_DIR, $INSTANCE)로 나란히 놓이며 서로 간섭하지 않습니다."
  warn "이관 절차 (가이드 §3 참조): 구 데몬을 정지·철거한 뒤 프로젝트별로 다시 설치하세요."
  warn "  sudo systemctl disable --now $UNIT_NAME"
  warn "  sudo rm -f $LEGACY_UNIT $LEGACY_BIN && sudo systemctl daemon-reload"
  warn "  (잡 이력이 필요하면 $LEGACY_STATE 를 새 프로젝트의 $DATA_DIR 로 옮긴 뒤 소유권을 $RUN_USER 로 맞추세요)"
  warn "──────────────────────────────────────────────"
fi

# ---------- 2. 바이너리 소스 확보 ----------
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t clickeye)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
mkdir -p "$TMP_DIR/x"

case $SRC_KIND in
  binary)
    # 소스 옵션이 없을 때의 순서: 스크립트 옆 daemond → 공개 배포 채널.
    #
    # 옆에 있는 것을 먼저 보는 이유는 폐쇄망이다. 반입물을 스크립트 옆에 놔두고 소스 옵션
    # 없이 돌리던 설치가 이 변경으로 갑자기 인터넷을 물면 그 설치는 실패하고, 실패 이유가
    # 네트워크로 보여 원인이 이 변경이라는 것을 알아채기 어렵다.
    #
    # --binary 로 명시한 경로는 없으면 폴백하지 않고 그대로 죽는다: 사람이 지목한 파일이
    # 없는 것은 폴백할 상황이 아니라 오타이며, 여기서 조용히 다운로드로 넘어가면 반입한
    # 것과 다른 바이너리가 설치된다.
    if [ -n "$BINARY" ]; then
      BIN_SRC=$BINARY
      [ -f "$BIN_SRC" ] || die "데몬 바이너리를 찾을 수 없습니다: $BIN_SRC — 경로를 확인하세요 (--binary 를 빼면 배포 채널에서 받습니다)"
      info "설치 소스: 로컬 바이너리 $BIN_SRC"
    elif [ "$CHANNEL_SET" -eq 0 ] && [ -f "$SCRIPT_DIR/daemond" ]; then
      # --channel 을 명시했으면 옆의 파일을 보지 않는다 — 채널을 고른 사람은 그 채널의 판을 원한다.
      BIN_SRC=$SCRIPT_DIR/daemond
      info "설치 소스: 로컬 바이너리 $BIN_SRC"
    else
      BIN_SRC=$TMP_DIR/daemond
      download_release_binary "$BIN_SRC"
    fi
    [ -x "$BIN_SRC" ] || warn "$BIN_SRC 에 실행권한이 없습니다 — 설치 시 0755 로 부여합니다"
    ;;
  zip)
    ARCHIVE=$TMP_DIR/pkg
    case $ZIP_SRC in
      http://*|https://*)
        case $ZIP_SRC in
          *.tar.gz|*.tgz) ARCHIVE=$TMP_DIR/pkg.tar.gz ;;
          *)              ARCHIVE=$TMP_DIR/pkg.zip ;;
        esac
        info "설치 소스: 아카이브 URL $ZIP_SRC"
        download_to "$ZIP_SRC" "$ARCHIVE"
        ;;
      *)
        [ -f "$ZIP_SRC" ] || die "아카이브를 찾을 수 없습니다: $ZIP_SRC"
        ARCHIVE=$ZIP_SRC
        info "설치 소스: 로컬 아카이브 $ARCHIVE"
        ;;
    esac
    if [ -n "$SHA256" ]; then
      verify_checksum "$ARCHIVE" "$SHA256"
    else
      warn "체크섬이 지정되지 않았습니다 — 아카이브 무결성 검증을 건너뜁니다"
      warn "  신뢰할 수 없는 경로로 받았다면 --sha256 <값|파일> 로 검증하세요"
    fi
    BIN_SRC=$TMP_DIR/daemond
    extract_daemond "$ARCHIVE" "$BIN_SRC"
    ;;
  git)
    info "설치 소스: git $GIT_URL"
    BIN_SRC=$TMP_DIR/daemond
    build_from_git "$BIN_SRC"
    ;;
esac

LOCAL_API_PORT=$(alloc_port)
if [ -z "$DAEMON_ID" ]; then
  # 한 호스트에 데몬이 여러 개 뜨므로 hostname 만으로는 중복된다 — 프로젝트를 붙인다.
  DAEMON_ID="$(uname -n)-$PROJECT"
fi

info "전제 검사 통과 (project=$PROJECT, systemd=$([ "$HAS_SYSTEMD" -eq 1 ] && echo yes || echo no), agent-cli=$AGENT_CLIS, node=$NODE_DESC)"

# ---------- 3. 환경 세팅 → 데몬 배치 (멱등) ----------
# 3-1) 시스템 사용자 (공용 — 모든 프로젝트가 공유한다)
if getent passwd "$RUN_USER" >/dev/null 2>&1; then
  info "시스템 사용자 $RUN_USER — 이미 존재 (통과)"
else
  NOLOGIN=$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)
  useradd -r -d "$BASE_DIR" -s "$NOLOGIN" "$RUN_USER"
  info "시스템 사용자 $RUN_USER 생성"
fi

# 3-2) 프로젝트 디렉터리 — 데이터·작업공간은 이 프로젝트 아래에만 만든다
#      프로젝트 디렉터리 자체는 root 소유(0755)로 둔다 — 그 안의 바이너리를
#      데몬 실행 사용자가 바꿔치기하지 못하게 한다. 쓰기가 필요한 데이터·작업공간만
#      $RUN_USER 소유로 내린다.
mkdir -p "$DATA_DIR" "$WORK_DIR" "$HOME_DIR"
chown root:root "$PROJ_DIR"
chmod 0755 "$PROJ_DIR"
chown "$RUN_USER:$RUN_USER" "$DATA_DIR" "$WORK_DIR" "$HOME_DIR"
chmod 0750 "$DATA_DIR" "$WORK_DIR" "$HOME_DIR"
info "프로젝트 디렉터리: $PROJ_DIR (data, workspaces, home)"

# 3-3) 바이너리 — 이 인스턴스가 실행 중이면 정지 후 교체 (업그레이드 경로).
#      다른 프로젝트의 인스턴스는 건드리지 않는다.
if [ "$HAS_SYSTEMD" -eq 1 ] && systemctl is-active --quiet "$INSTANCE" 2>/dev/null; then
  info "실행 중인 $INSTANCE 정지 (바이너리 교체를 위해)"
  systemctl stop "$INSTANCE"
fi
install -m 0755 -o root -g root "$BIN_SRC" "$BIN_DST"
info "바이너리 배치: $BIN_DST"

# 3-4) env 파일 (토큰이 들어간다 — 0600, $RUN_USER 소유. 기존 파일은 백업 후 갱신)
mkdir -p "$ENV_DIR"
chmod 0755 "$ENV_DIR"
if [ -f "$ENV_FILE" ]; then
  BACKUP=$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S).$$
  cp -p "$ENV_FILE" "$BACKUP"
  info "기존 env 백업: $BACKUP"
fi
OLD_UMASK=$(umask)
umask 077
{
  printf 'CLICKEYE_PROJECT=%s\n' "$PROJECT"
  printf 'CLICKEYE_CLOUD_URL=%s\n' "$CLOUD_URL"
  printf 'CLICKEYE_CLOUD_TOKEN=%s\n' "$TOKEN"
  printf 'CLICKEYE_REQUIRE_CLOUD=true\n'
  # 평문 ws:// 원격 접속 허용 — 위 「접속 주소 점검」이 경고하고 켠 경우에만.
  if [ "$INSECURE_WS" -eq 1 ]; then printf 'CLICKEYE_ALLOW_INSECURE_WS=1\n'; fi
  printf 'CLICKEYE_DATA_DIR=%s\n' "$DATA_DIR"
  printf 'CLICKEYE_WORKSPACE_DIR=%s\n' "$WORK_DIR"
  printf 'CLICKEYE_LOCAL_API=127.0.0.1:%s\n' "$LOCAL_API_PORT"
  printf 'CLICKEYE_DAEMON_ID=%s\n' "$DAEMON_ID"
  # HOME — 우리 변수가 아니지만 여기서 정한다. systemd 는 passwd 의 홈($BASE_DIR, 쓰기
  # 불가)을 넣으므로, 덮지 않으면 AI CLI 가 설정을 쓰지 못해 출력 없이 멈춘다(set_project_paths 주석).
  printf 'HOME=%s\n' "$HOME_DIR"
  # AI CLI 자격 — **지정된 쪽만** 쓴다. 빈 값으로 써 두면 CLI 는 "설정됐지만 비어 있다"로
  # 읽어 인증 실패 메시지가 달라지고, 무엇이 빠졌는지 찾기 어려워진다.
  # `[ -n x ] && printf` 로 쓰지 않는다: set -e 아래에서 그 AND-OR 리스트는 조건이 거짓일 때
  # 통째로 실패로 평가되어 **자격을 안 넣은 설치가 여기서 죽는다** — 그게 기본 경로다.
  if [ -n "$ANTHROPIC_KEY" ]; then printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_KEY"; fi
  if [ -n "$OAUTH_TOKEN" ];   then printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$OAUTH_TOKEN"; fi
  # 저장소 토큰 — 데몬이 기동 때 읽어 **자기 환경에서는 지우고** 메모리에 든다. 그래야 잡
  # 스텝이 물려받지 못하고(권한 우회로 도는 AI 가 자기 PR 을 머지하지 못한다), 관제가 나중에
  # 중앙에서 내려보내는 값과 경로가 하나로 합쳐진다.
  if [ -n "$GH_TOKEN_VALUE" ]; then printf 'GH_TOKEN=%s\n' "$GH_TOKEN_VALUE"; fi
} > "$ENV_FILE.tmp"
umask "$OLD_UMASK"
chown "$RUN_USER:$RUN_USER" "$ENV_FILE.tmp"
chmod 0600 "$ENV_FILE.tmp"
mv -f "$ENV_FILE.tmp" "$ENV_FILE"
info "env 작성: $ENV_FILE (0600, $RUN_USER 소유, localapi=127.0.0.1:$LOCAL_API_PORT)"

# 3-4b) 연결 확인 — CLI 가 **데몬이 실제로 쓸 환경 그대로** 인증되는지 한 번 호출해 본다.
#
# 설치가 끝났다는 말과 잡이 돌 것이라는 말은 다르다. 자격이 틀렸거나 실행 사용자가 CLI 를
# 못 돌리는 상태는 지금까지 첫 잡이 실패한 뒤에야 드러났고, 그 화면(로그 없는 타임아웃)
# 에서는 원인을 짚을 수 없었다. 그래서 여기서 미리 한 번 부딪혀 본다.
#
# 실패해도 설치를 되돌리지 않는다(warn). 데몬 자체는 정상 접속하고, 자격은 env 를 고쳐
# 재기동하면 되며, 부재 사실은 콘솔이 환경 리포트로 이미 보여 준다 — git·Node 를 경고로
# 낮춘 것과 같은 판단이다.
#
# 자격을 **인자로 넘기지 않는다.** `su -c` 의 명령 문자열은 ps 에 그대로 보이므로, 경로만
# 넘기고 값은 그 안에서 0600 env 파일을 읽어 채운다.
if [ -n "$ANTHROPIC_KEY" ] || [ -n "$OAUTH_TOKEN" ]; then
  if command -v claude >/dev/null 2>&1; then
    info "연결 확인: $RUN_USER 로 claude 를 한 번 호출합니다 (최대 90초)"
    VA_CMD="set -a; . '$ENV_FILE'; set +a; exec claude -p 'Reply with exactly: OK'"
    if command -v timeout >/dev/null 2>&1; then
      VA_OUT=$(timeout 90 su -s /bin/sh "$RUN_USER" -c "$VA_CMD" 2>&1) || true
    else
      VA_OUT=$(su -s /bin/sh "$RUN_USER" -c "$VA_CMD" 2>&1) || true
    fi
    case $VA_OUT in
      *OK*)
        info "연결 확인 통과 — AI 스텝이 실행 가능합니다" ;;
      '')
        # 실측된 모습이다: 실행 사용자가 홈에 쓰지 못하면 출력이 통째로 비고 타임아웃난다.
        warn "연결 확인 실패 — CLI 가 아무 출력도 내지 않았습니다(타임아웃)."
        warn "  실행 사용자가 홈($HOME_DIR)에 쓸 수 있는지 확인하세요. 잡은 로그 없이 실패합니다." ;;
      *)
        warn "연결 확인 실패 — CLI 가 인증되지 않았습니다:"
        printf '%s\n' "$VA_OUT" | head -5 | sed 's/^/[install]   /' >&2
        warn "  자격을 고치려면 $ENV_FILE 을 수정하고 서비스를 재기동하세요." ;;
    esac
  fi
else
  info "AI CLI 자격이 지정되지 않았습니다 — 데몬은 접속하지만 AI 스텝은 실패합니다(가이드 §1.3)"
fi

# 3-5) systemd 템플릿 유닛 (공용 — %i 가 프로젝트 이름으로 치환된다)
cat > "$TEMPLATE_UNIT" <<'UNIT'
[Unit]
Description=ClickEye execution daemon (project %i)
After=network-online.target
Wants=network-online.target

[Service]
User=clickeye
EnvironmentFile=/etc/clickeye/%i.env
WorkingDirectory=/opt/clickeye/%i
ExecStart=/opt/clickeye/%i/daemond
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
info "systemd 템플릿 유닛 배치: $TEMPLATE_UNIT (인스턴스: $INSTANCE)"

# ---------- 3.9 관제 접속 점검 ----------
# 띄우기 전에 「이 호스트에서 이 주소·토큰으로 관제에 닿는가」를 순서대로 본다(daemond check). 막혀도 설치는 계속한다 —
# 데몬은 떠서 다시 붙기를 반복하므로, 주소·방화벽을 고친 뒤 재설치 없이 붙을 수 있다. 어디에서 막혔는지는 여기서 보인다.
# check 를 모르는 옛 바이너리는 인자를 무시하고 데몬으로 떠 버리므로, 그 문구가 든 바이너리에서만 돌린다.
if grep -q 'daemond check' "$BIN_DST" 2>/dev/null || grep -aq '관제 접속 점검' "$BIN_DST" 2>/dev/null; then
  info "관제 접속 점검 — 어디에서 막히는지 순서대로 봅니다:"
  if ( set -a; . "$ENV_FILE"; set +a; "$BIN_DST" check ) 2>&1 | sed 's/^/[install]   /'; then :; fi
else
  info "관제 접속 점검을 건너뜁니다 — 이 바이너리에는 check 명령이 없습니다(옛 판)"
fi

# ---------- 4. 기동 + 검증 ----------
if [ "$NO_START" -eq 1 ]; then
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl daemon-reload
  fi
  info "──────────────────────────────────────────────"
  info "완료 (--no-start): 프로젝트 '$PROJECT' 파일 배치까지 끝났습니다. 기동은:"
  info "  sudo systemctl daemon-reload && sudo systemctl enable --now $INSTANCE"
  exit 0
fi

systemctl daemon-reload
systemctl enable "$INSTANCE"
systemctl restart "$INSTANCE"
info "$INSTANCE enable + (re)start 완료 — localapi 응답 대기"

STATUS_URL=http://127.0.0.1:$LOCAL_API_PORT/api/status

# 폴링: curl → wget → node fetch 순 폴백
probe() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "$STATUS_URL" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 2 -t 1 -O /dev/null "$STATUS_URL" 2>/dev/null
  elif command -v node >/dev/null 2>&1; then
    node -e "fetch('$STATUS_URL').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null
  else
    return 2
  fi
}

i=0
while [ "$i" -lt "$HEALTH_TRIES" ]; do
  PROBE_RC=0
  probe || PROBE_RC=$?
  if [ "$PROBE_RC" -eq 0 ]; then
    info "──────────────────────────────────────────────"
    info "설치 성공: $INSTANCE 기동 확인 ($STATUS_URL 응답)"
    info "다음 확인: 관제 콘솔 데몬 목록에 프로젝트 '$PROJECT' 가 온라인으로 표시되는지"
    info "  (git·Node·AI CLI 등 환경 미비는 콘솔의 데몬 환경 리포트에서 확인합니다)"
    exit 0
  fi
  if [ "$PROBE_RC" -eq 2 ]; then
    warn "curl/wget/node 가 없어 기동 검증을 건너뜁니다 — 수동 확인: systemctl status $INSTANCE"
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done

warn "──────────────────────────────────────────────"
warn "설치 실패: $STATUS_URL 이 ${HEALTH_TRIES}초 안에 응답하지 않았습니다"
warn "로그를 확인하세요: journalctl -u $INSTANCE -n 20"
warn "(토큰/URL 오류로 인한 fail-closed 기동 거부가 가장 흔한 원인 — 가이드 §7)"
exit 1

}

main "$@"
