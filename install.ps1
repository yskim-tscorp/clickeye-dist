<#
clickeye-daemon 설치 스크립트 (Windows) — **프로젝트당 데몬 하나** (멱등 — 재실행 = 그 프로젝트만 업그레이드)

이 파일은 새 설계가 아니라 정본 `install.sh` 의 **Windows 번역**이다. 인터페이스·멱등성·
프로젝트당 하나·포트 배정·철거·검증 문구의 판단은 전부 그쪽에 있고, 여기서는 같은 판단을
Windows 의 수단(작업 스케줄러·ACL·ProgramData)으로 옮긴다. 규칙이 갈리면 문서가 두 말을
하게 되므로, sh 를 고쳤으면 이 파일도 함께 고친다.

사용법 (콘솔 위저드가 이 형태로 원라이너를 생성한다 — 인터페이스 동결):
  파이프 실행 (파일을 남기지 않는다 — 기본 권장. 관리자 권한 PowerShell 에서):
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/yskim-tscorp/clickeye-dist/main/install.ps1).TrimStart([char]0xFEFF))) `
        -Project <이름> -CloudUrl wss://<host>/ws/daemon -Token <토큰>
  파일 실행 (폐쇄망·수동 반입):
    .\install.ps1 -Project <이름> -CloudUrl wss://<host>/ws/daemon -Token <토큰> `
        [소스옵션] [-DaemonId <ID>] [-NoStart]

  (sh 와 나란히 두면:
     curl -fsSL .../install.sh | sudo sh -s -- --project <이름> --cloud-url ... --token ...
   ↔ & ([scriptblock]::Create((irm .../install.ps1).TrimStart([char]0xFEFF))) -Project <이름> -CloudUrl ... -Token ... )

  **`.TrimStart([char]0xFEFF)` 를 빼면 안 된다.** 이 파일은 UTF-8 BOM 으로 저장돼 있어야
  하는데([W1]), PowerShell 5.1 의 Invoke-RestMethod 는 그 BOM 을 문자열 선두에 U+FEFF 로
  **남긴다**(실측). 그러면 `[scriptblock]::Create()` 가 첫 줄의 `<#` 를 블록 주석 시작으로
  인식하지 못해 파일 전체가 파서 오류로 거부된다. BOM 을 떼면 두 경로가 다 산다:
  파일 실행은 BOM 덕에 한국어가 살고, 파이프 실행은 TrimStart 덕에 파싱이 된다.

설치 소스 3종 — 하나만 지정한다 (여러 개면 거부):
  -Binary <경로>              로컬 바이너리 (기본: 스크립트 옆 .\daemond.exe)
  -Zip <경로|URL>             압축 안의 daemond.exe 를 꺼내 설치. URL 이면 받아서.
                              -Sha256 <값|파일> 이 함께 오면 검증 후에만 설치한다.
  -Git <repo-url> [-GitRef <ref>]
                              clone 후 go build. **소스 리포는 비공개라 자격증명이 필요하다.**

같은 값을 환경변수로도 받는다 (플래그가 우선):
  CLICKEYE_CLOUD_URL / CLICKEYE_CLOUD_TOKEN / CLICKEYE_DAEMON_ID

-NoStart : 파일 배치까지만 수행 (작업 등록·기동 없음 — CI 검증용)

철거 — 프로젝트 단위 (다른 프로젝트는 건드리지 않는다):
  .\install.ps1 -Uninstall -Project <이름>
  .\install.ps1 -Uninstall -Project <이름> -PurgeData

경로 레이아웃 (프로젝트별로 완전히 분리된다):
  C:\ProgramData\ClickEye\<project>\daemond.exe          바이너리
  C:\ProgramData\ClickEye\<project>\{data,workspaces}     데이터·작업공간
  C:\ProgramData\ClickEye\<project>\daemon-launcher.cmd   설정+기동 런처 (ACL 잠금 — 토큰이 들어간다)
  작업 스케줄러  \ClickEye\clickeye-daemon-<project>      부팅 시 SYSTEM 으로 기동

──────────────────────────────────────────────────────────────────────────────
Windows 고유 결정과 근거 (sh 와 갈리는 지점만)

[W1] PowerShell 5.1 호환. Windows Server 2016/2019 에 기본 탑재된 것이 5.1(Desktop)이고
     폐쇄망 고객서버에 PowerShell 7 을 추가 반입하는 것은 "추가 반입물 0" 원칙에 어긋난다.
     따라서 `&&`/`||`(파서 오류), 삼항 `? :`, `??`, `?.`, `-AsHashtable` 을 쓰지 않는다.
     비 ASCII 리터럴(이 파일의 한국어) 때문에 **파일은 UTF-8 BOM 으로 저장해야 한다** —
     5.1 은 BOM 이 없으면 스크립트를 시스템 ANSI 코드페이지(한국어 Windows 는 949)로 읽는다.
     실측: BOM 을 떼고 5.1 로 파싱하면 한국어가 깨지는 정도가 아니라 **파서 오류 32개로
     아예 실행되지 않는다**(깨진 바이트가 `[`·`%` 같은 연산자 자리에 떨어진다).
     7.x 는 BOM 없이도 UTF-8 로 읽으므로 BOM 이 양쪽을 다 만족시키는 쪽이다.
     BOM 이 파이프 실행에 미치는 영향과 그 대처는 파일 상단 "사용법" 절을 본다.

[W2] 관리자 권한. Windows 에는 sudo 가 없으므로 WindowsPrincipal 로 Administrator 역할을
     확인한다. UAC 자동 승격은 하지 않는다 — 파이프 실행 중에 승격하면 새 프로세스로
     넘어가면서 인자(토큰 포함)를 커맨드라인에 다시 실어야 하고, 그 커맨드라인은
     프로세스 목록에서 다른 사용자에게 보인다.

[W3] 토큰 보관 = 런처 + ACL. 작업 스케줄러는 systemd 의 EnvironmentFile 에 해당하는 기능이
     없다(작업 XML 에 환경변수를 실을 수 없다). 그래서 env 를 세팅하고 daemond.exe 를
     띄우는 **런처 .cmd** 를 두고, 그 파일을 ACL 로 SYSTEM + Administrators 만 읽게 잠근다
     (상속 제거) — sh 의 0600 에 대응한다.
       · 왜 .cmd 인가: .ps1 런처는 실행 정책(ExecutionPolicy)에 걸릴 수 있고 그것을 우회하려면
         작업에 -ExecutionPolicy Bypass 를 박아야 한다. .cmd 는 정책 대상이 아니다.
       · 왜 머신 전역 환경변수가 아닌가: 그 방식은 토큰을 이 호스트의 **모든 프로세스**에
         노출한다(잡이 실행하는 AI CLI 와 빌드 스크립트 포함). 명시적으로 금지한다.
       · 왜 ACL 을 SID 로 주는가: "Administrators" 는 지역화된 Windows 에서 이름이 다르다
         (Administrateurs 등). SID(S-1-5-18 / S-1-5-32-544)는 어느 로케일에서도 같다.

[W4] 경로 = C:\ProgramData\ClickEye\<project>. ProgramData 는 머신 전역 애플리케이션 상태의
     관례적 자리이고 SYSTEM 이 접근할 수 있으며 사용자 프로필 삭제에 영향받지 않는다.
     sh 는 프로그램(/opt)과 설정(/etc)을 나누지만 여기서는 한 뿌리에 둔다 — 그 분리의 목적이던
     "데몬 실행 사용자가 자기 바이너리를 바꿔치기하지 못하게 한다"는 [W5] 대로 작업이
     SYSTEM 으로 도는 이상 애초에 달성 불가능하기 때문이다(SYSTEM 은 어디든 쓴다).
     달성 가능한 보호는 **비관리자 사용자의 쓰기·읽기를 막는 것**이고 그것은 프로젝트
     디렉터리 ACL 로 한다.

[W5] 실행 계정 = SYSTEM. sh 는 비특권 사용자 clickeye 로 내리지만, 작업 스케줄러에서
     로컬 사용자로 무인 기동하려면 그 계정의 **암호를 저장**하거나 "배치 작업으로 로그온"
     권한(SeBatchLogonRight)을 별도 부여해야 한다 — 폐쇄망 고객서버에 암호 관리 부담을
     새로 만드는 선택이다. LocalService/NetworkService 는 프로필이 제약되어 git·Node·AI CLI
     실행에 부적합하다. 그래서 SYSTEM 을 쓴다. **이것은 sh 대비 권한 축소가 후퇴한 지점이며
     잔여 리스크로 명시한다** — 네이티브 서비스 지원(x/sys/windows/svc)으로 가면서 전용
     가상 서비스 계정(NT SERVICE\...)으로 좁히는 것이 다음 라운드의 몫이다.

[W6] "실패 시 재시작"(sh 의 Restart=always) = 두 겹.
       · RestartCount/RestartInterval — 작업이 실패로 끝났을 때의 즉시 재시도.
       · 1분 반복 트리거 + MultipleInstances=IgnoreNew — 프로세스가 어떤 이유로든 사라졌으면
         다음 분에 다시 뜨고, 살아 있으면 새 인스턴스는 무시된다.
     둘 중 하나만으로는 부족하다: RestartCount 는 횟수 상한이 있고, 반복 트리거만으로는
     최대 1분의 공백이 생긴다.
     ExecutionTimeLimit=0(무제한)이 중요하다 — 기본값(3일)이면 상주 데몬이 사흘째에 강제 종료된다.

[W7] localapi 포트는 sh 와 **같은 대역·같은 규칙**(58800-58999)이다. sh 는 `cksum`(POSIX CRC-32)
     으로 이름에서 결정적으로 뽑으므로 여기서도 같은 알고리즘을 구현했다(Get-PosixCksum).
     한 호스트에 sh 설치와 ps1 설치가 공존할 일은 없지만, 규칙이 갈리면 가이드 문서가
     "프로젝트 이름에서 포트가 결정된다"고 해놓고 두 값을 내놓게 된다.

[W8] -NoStart 는 작업을 **등록하지 않는다**. sh 의 --no-start 는 유닛 파일을 놓되 enable 하지
     않으므로 부팅 시 아무 일도 없다. Windows 에서 작업 등록은 그 자체가 "부팅 시 실행"을
     켜는 행위라, 등록까지 하면 --no-start 의 의미(아직 아무것도 살아나지 않는다)가 깨진다.

[W9] 스코프. 파이프 실행은 이 파일을 `[scriptblock]::Create()` 로 만들어 `&` 로 부른다. 그때
     `$script:` 는 **스크립트블록이 아니라 호출자의 스코프**를 가리키므로, 파라미터를
     `$script:CloudUrl` 처럼 쓰면 파일 실행에서는 되고 파이프 실행에서는 값이 비는 버그가
     된다. 그래서 파라미터는 Invoke-Main 이 해시테이블 하나($cfg)로 정리해 **인자로**
     내려보내고, 이 스크립트는 `$script:` 쓰기를 하지 않는다.
     같은 이유로 실패 시 `exit` 를 무조건 부르지 않는다 — 스크립트블록 안의 `exit` 는
     운영자의 관리자 콘솔 자체를 닫아 버린다. 파일 실행일 때만 exit 하고, 파이프 실행에서는
     $LASTEXITCODE 만 세운다.
──────────────────────────────────────────────────────────────────────────────
#>

[CmdletBinding()]
param(
    [string]$Project,
    [string]$CloudUrl,
    [string]$Token,
    [string]$Binary,
    [string]$Zip,
    [string]$Sha256,
    [string]$Git,
    [string]$GitRef,
    [string]$DaemonId,
    # AI CLI 자격 — 배타이며 **선택**이다. 없이 설치해도 데몬은 뜨고 AI 스텝만 죽는다.
    # sh 와 같은 판단으로 환경변수 폴백을 두지 않는다: 설치를 실행한 사람의 개인 키가
    # 고객서버 런처에 조용히 굳는 것을 막는다 — 자격은 명시적으로 건네는 값이어야 한다.
    [string]$AnthropicKey,
    [string]$OauthToken,
    [switch]$NoStart,
    [switch]$Uninstall,
    [switch]$PurgeData,
    [switch]$Help
)

# sh 의 `set -eu` 대응. 미선언 변수 참조를 잡아 두면 오타가 조용히 빈 문자열이 되어
# 엉뚱한 경로를 만드는 사고를 막는다.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------- 상수 (프로젝트 무관) ----------
$BaseDir       = Join-Path $env:ProgramData 'ClickEye'
$TaskFolder    = '\ClickEye\'
$TaskPrefix    = 'clickeye-daemon-'
$LauncherName  = 'daemon-launcher.cmd'
$HealthTries   = 15

# 프로젝트별 localapi 포트 대역 — 한 호스트에 데몬이 여러 개 뜨므로
# 전부 기본 58787 을 물면 두 번째부터 EADDRINUSE 로 죽는다. (install.sh 와 같은 값)
$PortBase = 58800
$PortSpan = 200

# ACL 대상 SID — 지역화 무관 ([W3])
$SidSystem = '*S-1-5-18'      # NT AUTHORITY\SYSTEM
$SidAdmins = '*S-1-5-32-544'  # BUILTIN\Administrators

# ---------- 출력 ----------
# sh 의 info/warn/die 와 같은 접두사를 쓴다. 두 스크립트의 로그를 같은 눈으로 읽게 하기 위함.
function Write-Info {
    param([string]$Message)
    Write-Host ('[install] {0}' -f $Message)
}

function Write-Warn {
    param([string]$Message)
    # Write-Warning 은 "WARNING: " 접두사를 붙여 sh 와 문구가 달라진다. stderr 로 직접 쓴다.
    [Console]::Error.WriteLine('[install] 경고: {0}' -f $Message)
}

# sh 의 die() — 중단. 예외로 던지고 최상단에서 잡아 한 줄 사유로 출력한다
# (파이프 실행에서도 스택 트레이스 대신 사유가 보이도록).
function Stop-Install {
    param([string]$Message)
    throw ('[install] 오류: {0}' -f $Message)
}

function Show-Usage {
    $text = @'
설치: .\install.ps1 -Project <이름> -CloudUrl wss://<host>/ws/daemon -Token <토큰> `
           [-Binary <경로> | -Zip <경로|URL> [-Sha256 <값|파일>] | -Git <repo-url> [-GitRef <ref>]] `
           [-DaemonId <ID>] [-NoStart]

  -Project <이름>   필수. 이 호스트에서 데몬을 구분하는 식별자이자 경로·작업 이름.
                    허용 문자: A-Z a-z 0-9 . _ - (공백·슬래시·'..' 는 거부)
                    '-' 로 시작하는 값은 어차피 거부되지만, PowerShell 이 값을 플래그로
                    읽지 않게 하려면 -Project:"<값>" 형태로 준다.
  -Binary <경로>    로컬 바이너리 (기본: 스크립트 옆 .\daemond.exe)
  -Zip <경로|URL>   압축 안의 daemond.exe 를 꺼내 설치 (.zip / .tar.gz)
  -Sha256 <값|파일> -Zip 아카이브의 SHA-256. 없으면 검증을 건너뛴다(경고).
  -Git <repo-url>   clone 후 go build (Go 툴체인 필요 / 비공개 리포는 자격증명 필요)
  -GitRef <ref>     -Git 과 함께 — 브랜치·태그·커밋
  -DaemonId <ID>    데몬 식별자 (기본: <hostname>-<project>)
  -AnthropicKey <값>  AI CLI 자격 — 런처에 ANTHROPIC_API_KEY 로 기록 (Console 조직 키)
  -OauthToken <값>    AI CLI 자격 — 런처에 CLAUDE_CODE_OAUTH_TOKEN 로 기록
                      (구독 토큰. 브라우저 있는 호스트에서 claude setup-token 으로 발급)
                      위 둘은 배타이며 **선택**이다 — 없어도 설치는 되고 AI 스텝만 실패한다.
  -NoStart          파일 배치까지만 — 작업 등록·기동 없음 (CI 검증용)

철거: .\install.ps1 -Uninstall -Project <이름> [-PurgeData]
      -Uninstall    그 프로젝트의 작업·바이너리·런처(토큰 포함)만 제거.
                    다른 프로젝트의 작업은 건드리지 않는다.
      -PurgeData    그 프로젝트의 데이터(C:\ProgramData\ClickEye\<이름>)까지 제거.

환경변수로도 지정 가능(플래그 우선): CLICKEYE_CLOUD_URL, CLICKEYE_CLOUD_TOKEN, CLICKEYE_DAEMON_ID
'@
    [Console]::Error.WriteLine($text)
}

# ---------- 프로젝트 이름 검증 ----------
# -Project 는 경로(C:\ProgramData\ClickEye\<이름>)와 작업 이름(clickeye-daemon-<이름>)에
# 그대로 들어간다. 즉 신뢰할 수 없는 값이 파일시스템 경로가 되므로 화이트리스트로 막는다.
#
# **이 규칙의 정본은 daemon/scripts/install.sh 의 validate_project() 다.**
# 이 함수는 그 규칙의 **네 번째 복제본**이며 독자적 판단이 아니다. 네 곳 전부:
#   1. daemon/scripts/install.sh                                       validate_project()   ← 정본
#   2. cloud/internal/domain/projectcfg/identifier.go                  validateIdentifier()
#   3. cloud/frontend/src/entities/project-config/model/project-id.ts  getProjectIdViolation()
#   4. (여기) daemon/scripts/install.ps1                               Assert-ValidProject
# 넷 중 하나를 고치면 나머지 셋도 함께 고쳐야 한다. 규칙이 갈리면 어느 쪽으로 갈라져도
# 손해다 — 콘솔이 설치할 수 없는 이름을 발급하거나, 손으로는 설치되는 이름이 화면에서
# 등록되지 않는다.
#
# **검사 순서도 같다**: 화이트리스트 → '..' → 선행 '.' → 선행 '-' → 길이.
# 여러 규칙을 동시에 어긴 값에서 먼저 지적되는 사유가 네 곳에서 같아야, 화면과 서버와
# 고객서버가 같은 말을 한다. (길이를 문자셋 뒤에 두면 통과한 값은 전부 ASCII 라 .NET 의
# UTF-16 길이가 sh 가 세는 바이트 수와 언제나 일치한다는 부수 효과도 있다.)
function Assert-ValidProject {
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) {
        Show-Usage
        Stop-Install '-Project <이름> 이 필요합니다 — 프로젝트마다 데몬 하나를 설치합니다'
    }
    if ($Name -match '[^A-Za-z0-9._-]') {
        Stop-Install ("-Project 이름에 쓸 수 없는 문자가 있습니다: '{0}' (허용: A-Z a-z 0-9 . _ -)" -f $Name)
    }
    if ($Name.Contains('..')) {
        Stop-Install ("-Project 이름에 '..' 은 쓸 수 없습니다: '{0}' (경로 탈출 방지)" -f $Name)
    }
    if ($Name.StartsWith('.')) {
        Stop-Install ("-Project 이름은 '.' 으로 시작할 수 없습니다: '{0}'" -f $Name)
    }
    if ($Name.StartsWith('-')) {
        Stop-Install ("-Project 이름은 '-' 으로 시작할 수 없습니다: '{0}'" -f $Name)
    }
    if ($Name.Length -gt 64) {
        Stop-Install ("-Project 이름이 너무 깁니다 (64자 이하): '{0}'" -f $Name)
    }
}

# 프로젝트에 종속된 경로들을 한자리에서 만든다 (sh 의 set_project_paths).
function Get-ProjectPaths {
    param([string]$Name, [string]$Root, [string]$Launcher, [string]$Prefix)
    $proj = Join-Path $Root $Name
    return @{
        ProjDir  = $proj
        BinDst   = Join-Path $proj 'daemond.exe'
        DataDir  = Join-Path $proj 'data'
        WorkDir  = Join-Path $proj 'workspaces'
        Launcher = Join-Path $proj $Launcher
        TaskName = $Prefix + $Name
    }
}

# ---------- 관리자 권한 ([W2]) ----------
function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        Stop-Install @'
관리자 권한이 필요합니다 — 관리자 권한 PowerShell 에서 실행하세요.
  시작 메뉴에서 "Windows PowerShell" 을 우클릭 → "관리자 권한으로 실행" 후 같은 명령을 다시 실행합니다.
  (sudo 에 해당하는 단계입니다. 자동 승격은 하지 않습니다 — 승격 시 토큰이 새 프로세스의
   커맨드라인에 실려 프로세스 목록에서 다른 사용자에게 보이기 때문입니다.)
'@
    }
}

# ---------- 포트 할당 ([W7]) ----------
# sh 는 `printf '%s' "$name" | cksum` 의 첫 필드를 쓴다. cksum 은 POSIX CRC-32 —
# 다항식 0x04C11DB7, 비반전(non-reflected), 초기값 0, **바이트열 뒤에 길이를 리틀엔디언
# 바이트 단위로 이어 넣고**, 최종 1의 보수. .NET 에 이 변종이 없어 직접 구현한다
# (System.IO.Hashing 의 Crc32 는 반전된 zlib 변종이라 값이 다르다).
function Get-PosixCksum {
    param([string]$Text)

    # **16진 리터럴에 L 접미사가 반드시 붙어야 한다.** PowerShell 5.1 은 접미사 없는
    # 0x80000000 / 0xFFFFFFFF 를 Int32 로 읽어 각각 -2147483648 / -1 이 되고, 그 음수를
    # [uint64] 로 캐스팅하면 "Value was either too large or too small" 로 죽는다.
    # L 을 붙이면 Int64 로 읽혀 의도한 양수가 된다.
    $poly = [uint64]0x04C11DB7L
    $mask = [uint64]0xFFFFFFFFL
    $top  = [uint64]0x80000000L
    $byte = [uint64]0xFFL

    $table = New-Object 'System.UInt32[]' 256
    for ($i = 0; $i -lt 256; $i++) {
        $c = ([uint64]$i -shl 24) -band $mask
        for ($k = 0; $k -lt 8; $k++) {
            if (($c -band $top) -ne 0) {
                $c = ((($c -shl 1) -band $mask) -bxor $poly)
            } else {
                $c = ($c -shl 1) -band $mask
            }
        }
        $table[$i] = [uint32]$c
    }

    # 프로젝트 이름은 검증을 통과한 뒤라 전부 ASCII 다 — UTF-8 바이트가 sh 가 세는
    # 바이트열과 언제나 같다.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $crc = [uint64]0
    foreach ($b in $bytes) {
        $idx = [int]((($crc -shr 24) -bxor [uint64]$b) -band $byte)
        $crc = ((($crc -shl 8) -band $mask) -bxor [uint64]$table[$idx])
    }
    # cksum 은 바이트열 뒤에 **길이를 리틀엔디언 바이트 단위로** 이어 넣는다.
    $len = [uint64]$bytes.Length
    while ($len -ne 0) {
        $idx = [int]((($crc -shr 24) -bxor ($len -band $byte)) -band $byte)
        $crc = ((($crc -shl 8) -band $mask) -bxor [uint64]$table[$idx])
        $len = $len -shr 8
    }
    return ($mask -bxor $crc)
}

function Get-DerivedPort {
    param([string]$Name, [int]$Base, [int]$Span)
    $n = Get-PosixCksum -Text $Name
    return [int]($Base + [int]($n % [uint64]$Span))
}

# 런처에서 이미 배정된 포트를 읽는다 (sh 가 env 파일에서 읽는 것과 같은 자리).
function Get-PortFromLauncher {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $m = Select-String -LiteralPath $Path -Pattern 'CLICKEYE_LOCAL_API=127\.0\.0\.1:(\d+)' -ErrorAction SilentlyContinue
    if ($null -eq $m) { return 0 }
    return [int]$m.Matches[0].Groups[1].Value
}

function Test-PortTakenByOther {
    param([int]$Port, [string]$SelfLauncher, [string]$Root, [string]$Launcher)
    if (-not (Test-Path -LiteralPath $Root)) { return $false }
    $others = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)
    foreach ($d in $others) {
        $lp = Join-Path $d.FullName $Launcher
        if ($lp -eq $SelfLauncher) { continue }
        if (-not (Test-Path -LiteralPath $lp)) { continue }
        if ((Get-PortFromLauncher -Path $lp) -eq $Port) { return $true }
    }
    return $false
}

function Get-AllocatedPort {
    param([string]$Name, [string]$SelfLauncher, [string]$Root, [string]$Launcher, [int]$Base, [int]$Span)

    # 이 프로젝트에 이미 할당된 포트가 있으면 그대로 재사용한다 — 재실행이 포트를
    # 바꾸면 방화벽·모니터링 설정이 매번 어긋난다(멱등성).
    $prev = Get-PortFromLauncher -Path $SelfLauncher
    if ($prev -ge $Base -and $prev -lt ($Base + $Span)) { return $prev }

    $cand = Get-DerivedPort -Name $Name -Base $Base -Span $Span
    for ($i = 0; $i -lt $Span; $i++) {
        if (-not (Test-PortTakenByOther -Port $cand -SelfLauncher $SelfLauncher -Root $Root -Launcher $Launcher)) {
            return $cand
        }
        $cand++
        if ($cand -ge ($Base + $Span)) { $cand = $Base }
    }
    Stop-Install ('localapi 포트 대역({0}-{1})이 가득 찼습니다 — 쓰지 않는 프로젝트를 철거하세요' -f $Base, ($Base + $Span - 1))
}

# ---------- ACL ([W3]) ----------
# 상속을 끊고 SYSTEM + Administrators 만 남긴다. sh 의 0600/0750 에 대응한다.
function Set-RestrictedAcl {
    param([string]$Path, [string]$System, [string]$Admins, [switch]$Container)

    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $grantSystem = $System + ':(F)'
    $grantAdmins = $Admins + ':(F)'
    if ($Container) {
        # (OI)(CI) — 이 아래 새로 생기는 파일·디렉터리가 같은 제한을 물려받는다.
        $grantSystem = $System + ':(OI)(CI)(F)'
        $grantAdmins = $Admins + ':(OI)(CI)(F)'
    }

    # /inheritance:r 로 상속된 ACE 를 전부 제거한 뒤, /grant:r 로 두 SID 만 명시 부여한다.
    # 순서가 반대면 상속 제거가 방금 준 권한까지 지운다.
    $out1 = & $icacls $Path '/inheritance:r' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-Install ("ACL 상속 제거 실패: {0}`n  {1}" -f $Path, ($out1 -join "`n  "))
    }
    $out2 = & $icacls $Path '/grant:r' $grantSystem $grantAdmins 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-Install ("ACL 설정 실패: {0}`n  {1}" -f $Path, ($out2 -join "`n  "))
    }
}

# ---------- 소스: 체크섬 ----------
function Assert-Checksum {
    param([string]$File, [string]$Expected)

    $expect = $Expected
    # 값이 아니라 체크섬 '파일'을 준 경우 첫 필드를 꺼낸다 (sha256sum 출력 형식).
    if (Test-Path -LiteralPath $expect -PathType Leaf) {
        $first = @(Get-Content -LiteralPath $expect -TotalCount 1)
        if ($first.Count -eq 0) {
            Stop-Install ('-Sha256 파일이 비어 있습니다: {0}' -f $Expected)
        }
        $expect = ($first[0] -split '\s+')[0]
    }
    if ([string]::IsNullOrEmpty($expect) -or ($expect -match '[^A-Fa-f0-9]')) {
        Stop-Install ("-Sha256 값이 16진수가 아닙니다: '{0}'" -f $Expected)
    }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    $e = $expect.ToLowerInvariant()
    $a = $actual.ToLowerInvariant()
    if ($e -ne $a) {
        Stop-Install ("체크섬 불일치 — 설치를 중단합니다`n  기대: {0}`n  실제: {1}`n  받은 파일이 손상되었거나 변조되었을 수 있습니다." -f $e, $a)
    }
    Write-Info ('체크섬 검증 통과 (sha256={0})' -f $a)
}

function Save-Download {
    param([string]$Url, [string]$OutFile)
    # Server 2016 의 .NET 기본 프로토콜에는 TLS 1.2 가 빠져 있을 수 있다 — 명시적으로 켠다.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Warn 'TLS 1.2 활성화에 실패했습니다 — 다운로드가 거부되면 호스트의 .NET/Schannel 설정을 확인하세요'
    }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
    } catch {
        Stop-Install ("다운로드 실패: {0}`n  {1}" -f $Url, $_.Exception.Message)
    }
    Write-Info ('다운로드 완료: {0}' -f $Url)
}

# ---------- 소스: 아카이브에서 daemond.exe 꺼내기 ----------
function Expand-DaemonArchive {
    param([string]$Archive, [string]$Destination, [string]$TempDir)

    $x = Join-Path $TempDir 'x'
    New-Item -ItemType Directory -Path $x -Force | Out-Null

    if ($Archive -match '\.(tar\.gz|tgz|tar)$') {
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (-not (Test-Path -LiteralPath $tar)) {
            Stop-Install 'tar.exe 가 없습니다 (Windows 10 1803 / Server 2019 이상에 기본 포함) — .zip 으로 받거나 직접 풀어 -Binary 로 주세요'
        }
        & $tar -xf $Archive -C $x
        if ($LASTEXITCODE -ne 0) { Stop-Install ('아카이브 해제 실패: {0}' -f $Archive) }
    } else {
        try {
            Expand-Archive -LiteralPath $Archive -DestinationPath $x -Force
        } catch {
            Stop-Install ("압축 해제 실패: {0}`n  {1}" -f $Archive, $_.Exception.Message)
        }
    }

    # 아카이브 안 어디에 있든 daemond.exe 를 찾는다 (루트/하위 디렉터리 모두 허용).
    $found = @(Get-ChildItem -LiteralPath $x -Recurse -File -Filter 'daemond.exe' -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) {
        # 확장자 없는 daemond 도 살펴본다 — Linux 아카이브를 잘못 반입한 경우를 분명히 알리기 위해.
        $alt = @(Get-ChildItem -LiteralPath $x -Recurse -File -Filter 'daemond' -ErrorAction SilentlyContinue)
        if ($alt.Count -gt 0) {
            Stop-Install ("아카이브에 Linux 용 'daemond' 가 들어 있습니다 (Windows 용 'daemond.exe' 가 아닙니다): {0}`n  GOOS=windows 로 빌드한 아카이브를 받으세요." -f $Archive)
        }
        Stop-Install ("아카이브 안에서 'daemond.exe' 를 찾지 못했습니다: {0}" -f $Archive)
    }
    Copy-Item -LiteralPath $found[0].FullName -Destination $Destination -Force
    Write-Info ('아카이브에서 추출: {0}' -f $found[0].FullName)
}

# ---------- 소스: git clone + go build ----------
function Build-FromGit {
    param([string]$RepoUrl, [string]$Ref, [string]$Destination, [string]$TempDir)

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        Stop-Install 'git 이 없습니다 — -Git 은 소스를 clone 해 빌드하는 경로입니다. 먼저 설치하세요 (winget install Git.Git)'
    }
    if ($null -eq (Get-Command go -ErrorAction SilentlyContinue)) {
        Stop-Install 'Go 툴체인이 없습니다 — -Git 은 소스에서 go build 로 만듭니다. Go 를 설치하거나 -Binary/-Zip 을 쓰세요'
    }

    if ([string]::IsNullOrEmpty($Ref)) {
        Write-Info ('소스 빌드: {0}' -f $RepoUrl)
    } else {
        Write-Info ('소스 빌드: {0} (ref: {1})' -f $RepoUrl, $Ref)
    }
    Write-Info '  참고: 소스 리포는 비공개입니다 — 이 호스트에 읽기 권한이 있는 자격증명이 있어야 합니다'
    Write-Info '  (SSH 배포키 / credential helper / URL 에 포함된 토큰 중 하나)'

    # 비대화식 — 자격증명이 없으면 암호 프롬프트에서 멈추지 말고 즉시 실패해야 한다.
    $env:GIT_TERMINAL_PROMPT = '0'
    $src = Join-Path $TempDir 'src'

    $cloned = $false
    if ([string]::IsNullOrEmpty($Ref)) {
        & git clone --depth 1 $RepoUrl $src 2>&1 | ForEach-Object { Write-Info ('  git| {0}' -f $_) }
        if ($LASTEXITCODE -eq 0) { $cloned = $true }
    } else {
        & git clone --depth 1 --branch $Ref $RepoUrl $src 2>&1 | ForEach-Object { Write-Info ('  git| {0}' -f $_) }
        if ($LASTEXITCODE -eq 0) { $cloned = $true }
    }

    if (-not $cloned) {
        # ref 가 커밋 SHA 면 --branch 로는 못 잡는다 — 전체 clone 후 checkout 으로 재시도.
        if ([string]::IsNullOrEmpty($Ref)) {
            Stop-Install ('clone 실패 — 비공개 리포입니다. 자격증명(SSH 키·토큰)을 확인하세요: {0}' -f $RepoUrl)
        }
        Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue
        & git clone $RepoUrl $src 2>&1 | ForEach-Object { Write-Info ('  git| {0}' -f $_) }
        if ($LASTEXITCODE -ne 0) {
            Stop-Install ('clone 실패 — 비공개 리포입니다. 자격증명(SSH 키·토큰)을 확인하세요: {0}' -f $RepoUrl)
        }
        & git -C $src checkout --detach $Ref 2>&1 | ForEach-Object { Write-Info ('  git| {0}' -f $_) }
        if ($LASTEXITCODE -ne 0) { Stop-Install ('ref 체크아웃 실패: {0}' -f $Ref) }
    }

    # 데몬 모듈 위치 — 모노레포(daemon/) 와 단독 리포 양쪽을 지원한다.
    $mod = $src
    if (Test-Path -LiteralPath (Join-Path $src 'daemon\cmd\daemond')) {
        $mod = Join-Path $src 'daemon'
    } elseif (-not (Test-Path -LiteralPath (Join-Path $src 'cmd\daemond'))) {
        Stop-Install '리포에서 cmd/daemond 를 찾지 못했습니다 — -Git 대상이 데몬 소스인지 확인하세요'
    }

    Write-Info 'go build 시작 (수 분 걸릴 수 있습니다)'
    $env:CGO_ENABLED = '0'
    Push-Location $mod
    try {
        & go build -trimpath '-ldflags=-s -w' -o $Destination ./cmd/daemond
        if ($LASTEXITCODE -ne 0) { Stop-Install 'go build 실패 — 위 컴파일 오류를 확인하세요' }
    } finally {
        Pop-Location
    }
    Write-Info ('빌드 완료: {0}' -f $Destination)
}

# ---------- 작업 스케줄러 ([W6]) ----------
function Get-DaemonTask {
    param([string]$TaskName, [string]$Folder)
    return (Get-ScheduledTask -TaskPath $Folder -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Register-DaemonTask {
    param([hashtable]$Cfg, [hashtable]$Paths)

    # 런처를 cmd.exe 로 실행한다. /c 로 띄우면 cmd 가 daemond.exe 의 부모로 남지만,
    # 작업 스케줄러는 작업 종료 시 프로세스 트리를 함께 정리하므로 정지 경로에 문제가 없다.
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $action = New-ScheduledTaskAction -Execute $cmdExe -Argument ('/c ""{0}""' -f $Paths.Launcher) -WorkingDirectory $Paths.ProjDir

    # 부팅 시 실행 — 로그인 없이 동작한다 (sh 의 WantedBy=multi-user.target).
    $trgBoot = New-ScheduledTaskTrigger -AtStartup
    # 살아있지 않으면 1분 안에 다시 뜬다 ([W6] 두 번째 겹).
    $trgKeep = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
        -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)

    # SYSTEM, 최고 권한 ([W5]). SID 로 지정한다 — 지역화 무관.
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -DontStopOnIdleEnd `
        -MultipleInstances IgnoreNew `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskPath $Cfg.TaskFolder -TaskName $Paths.TaskName `
        -Action $action -Trigger @($trgBoot, $trgKeep) -Principal $principal -Settings $settings `
        -Description ('ClickEye execution daemon (project {0})' -f $Cfg.Project) -Force | Out-Null
}

# 정지 후 exe 가 실제로 풀릴 때까지 기다린다. Windows 는 실행 중인 파일을 덮어쓰지 못하므로
# (Linux 와 다른 점) 여기서 기다리지 않으면 업그레이드가 "액세스가 거부되었습니다"로 깨진다.
function Stop-DaemonAndWait {
    param([string]$TaskName, [string]$Folder, [string]$BinPath)

    if ($null -ne (Get-DaemonTask -TaskName $TaskName -Folder $Folder)) {
        try {
            Stop-ScheduledTask -TaskPath $Folder -TaskName $TaskName -ErrorAction SilentlyContinue
        } catch {
            Write-Warn ('작업 정지 실패(또는 이미 정지) — 계속 진행합니다: {0}{1}' -f $Folder, $TaskName)
        }
    }
    if (-not (Test-Path -LiteralPath $BinPath)) { return }

    for ($i = 0; $i -lt 10; $i++) {
        try {
            $fs = [System.IO.File]::Open($BinPath, 'Open', 'ReadWrite', 'None')
            $fs.Close()
            return
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    Write-Warn ('{0} 이 아직 사용 중입니다 — 교체가 실패하면 실행 중인 daemond.exe 를 수동 종료하세요' -f $BinPath)
}

# ---------- 기동 검증 ----------
function Test-DaemonStatus {
    param([string]$Url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = 2000
        # 루프백 요청이 회사 프록시로 새지 않게 한다 — 프록시가 걸리면 상태 확인이
        # 데몬과 무관한 이유로 실패한다.
        $req.Proxy = $null
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -ge 200 -and $code -lt 300)
    } catch {
        return $false
    }
}

# ---------- 철거 (-Uninstall -Project <이름>) ----------
# 멱등 — 이미 없는 것은 경고만 하고 계속한다 (재실행 안전).
# 멀티 인스턴스 안전 — 이 프로젝트의 작업만 건드린다.
function Invoke-Uninstall {
    param([hashtable]$Cfg, [hashtable]$Paths)

    Assert-Administrator

    Write-Info ("프로젝트 '{0}' 철거 — 작업 {1}{2}" -f $Cfg.Project, $Cfg.TaskFolder, $Paths.TaskName)
    if ($Cfg.PurgeData) {
        Write-Info '완전 철거(-PurgeData) — 표준 철거 대상에 더해 다음을 삭제합니다:'
        Write-Info ('  - {0} (이 프로젝트의 잡 이력·작업공간 전체)' -f $Paths.ProjDir)
    }

    $found = $false

    # 1) 이 작업만 정지 + 등록 해제
    if ($null -ne (Get-DaemonTask -TaskName $Paths.TaskName -Folder $Cfg.TaskFolder)) {
        Stop-DaemonAndWait -TaskName $Paths.TaskName -Folder $Cfg.TaskFolder -BinPath $Paths.BinDst
        Unregister-ScheduledTask -TaskPath $Cfg.TaskFolder -TaskName $Paths.TaskName -Confirm:$false
        Write-Info ('작업 등록 해제: {0}{1}' -f $Cfg.TaskFolder, $Paths.TaskName)
        $found = $true
    } else {
        Write-Warn ('이미 없음(통과): 작업 {0}{1}' -f $Cfg.TaskFolder, $Paths.TaskName)
    }

    # 2) 런처 제거 — **토큰이 든 파일**이므로 반드시 지운다 (sh 의 env 제거에 대응)
    if (Test-Path -LiteralPath $Paths.Launcher) {
        Remove-Item -LiteralPath $Paths.Launcher -Force
        Write-Info ('제거: {0} (토큰이 든 런처)' -f $Paths.Launcher)
        $found = $true
    } else {
        Write-Warn ('이미 없음(통과): {0}' -f $Paths.Launcher)
    }
    if (Test-Path -LiteralPath $Paths.ProjDir) {
        $baks = @(Get-ChildItem -LiteralPath $Paths.ProjDir -Filter ($Cfg.LauncherName + '.bak.*') -File -ErrorAction SilentlyContinue)
        foreach ($b in $baks) {
            Remove-Item -LiteralPath $b.FullName -Force
            Write-Info ('제거: {0} (런처 백업)' -f $b.FullName)
        }
    }

    # 3) 바이너리 제거 (데이터는 남긴다)
    if (Test-Path -LiteralPath $Paths.BinDst) {
        Remove-Item -LiteralPath $Paths.BinDst -Force
        Write-Info ('제거: {0}' -f $Paths.BinDst)
        $found = $true
    } else {
        Write-Warn ('이미 없음(통과): {0}' -f $Paths.BinDst)
    }

    # 4) 데이터 — 기본 보존, -PurgeData 에서만 제거
    if ($Cfg.PurgeData) {
        if (Test-Path -LiteralPath $Paths.ProjDir) {
            Remove-Item -LiteralPath $Paths.ProjDir -Recurse -Force
            Write-Info ('제거: {0} (잡 이력·작업공간)' -f $Paths.ProjDir)
        } else {
            Write-Warn ('이미 없음(통과): {0}' -f $Paths.ProjDir)
        }
    }

    if (-not $found) {
        Write-Warn ("프로젝트 '{0}' 의 설치 흔적을 찾지 못했습니다 — 이미 철거되었거나 이름이 다를 수 있습니다" -f $Cfg.Project)
        $names = @()
        if (Test-Path -LiteralPath $Cfg.BaseDir) {
            $names = @(Get-ChildItem -LiteralPath $Cfg.BaseDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        }
        if ($names.Count -eq 0) {
            Write-Warn '설치된 프로젝트 목록: (없음)'
        } else {
            Write-Warn ('설치된 프로젝트 목록: {0}' -f ($names -join ' '))
        }
    }

    # 5) 공용 자원 정리 — **마지막 인스턴스일 때만**.
    #    Windows 에는 sh 의 템플릿 유닛·시스템 사용자에 해당하는 공유물이 없다(작업이
    #    프로젝트별로 완결되고, 실행 계정은 이미 존재하는 SYSTEM 이다). 남는 공용물은
    #    뿌리 디렉터리와 작업 폴더뿐이라 둘 다 비었을 때만 치운다.
    $remaining = 0
    if (Test-Path -LiteralPath $Cfg.BaseDir) {
        $remaining = @(Get-ChildItem -LiteralPath $Cfg.BaseDir -Directory -ErrorAction SilentlyContinue).Count
    }
    if ($remaining -gt 0) {
        Write-Info ('다른 프로젝트 디렉터리 {0}개가 남아 있습니다 — 공용 자원(작업 폴더 {1}, {2})은 보존합니다' -f $remaining, $Cfg.TaskFolder, $Cfg.BaseDir)
    } else {
        if (Test-Path -LiteralPath $Cfg.BaseDir) {
            Remove-Item -LiteralPath $Cfg.BaseDir -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $Cfg.BaseDir)) {
                Write-Info ('제거: {0} (비어 있음)' -f $Cfg.BaseDir)
            }
        }
        # 작업 폴더는 cmdlet 으로 지울 수 없어 COM 스케줄러 API 를 쓴다. 비어 있지 않으면
        # 실패하는데, 그 경우 다른 프로젝트가 남아 있다는 뜻이므로 보존이 맞다.
        try {
            $svc = New-Object -ComObject 'Schedule.Service'
            $svc.Connect()
            $svc.GetFolder('\').DeleteFolder($Cfg.TaskFolder.Trim('\'), 0)
            Write-Info ('제거: 작업 폴더 {0} (비어 있음)' -f $Cfg.TaskFolder)
        } catch {
            # 폴더가 없거나 비어 있지 않다 — 어느 쪽이든 정상 경로다.
        }
    }

    Write-Info '──────────────────────────────────────────────'
    Write-Info ("철거 완료: 프로젝트 '{0}'" -f $Cfg.Project)
}

# 런처 작성 ([W3]). sh 의 /etc/clickeye/<project>.env + systemd EnvironmentFile 을 한 파일이 겸한다.
function Write-DaemonLauncher {
    param([hashtable]$Cfg, [hashtable]$Paths, [int]$Port, [string]$DaemonIdValue)

    # 토큰이 담기므로, **빈 파일을 먼저 만들고 ACL 을 잠근 뒤** 내용을 쓴다 — 평문이
    # 넓은 권한으로 디스크에 존재하는 창을 없앤다.
    if (Test-Path -LiteralPath $Paths.Launcher) { Remove-Item -LiteralPath $Paths.Launcher -Force }
    New-Item -ItemType File -Path $Paths.Launcher -Force | Out-Null
    Set-RestrictedAcl -Path $Paths.Launcher -System $Cfg.SidSystem -Admins $Cfg.SidAdmins

    # cmd.exe 의 `set "K=V"` 는 공백·`&`·`^`·`|` 를 그대로 담지만 `%` 는 변수 확장으로
    # 먹힌다 — 배치 파일에서는 `%%` 로 이스케이프한다.
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('@echo off')
    $lines.Add('rem ClickEye daemon launcher - generated by install.ps1. Do not edit by hand.')
    $lines.Add('rem Re-run install.ps1 to regenerate. This file carries the cloud token and is')
    $lines.Add('rem ACL-locked to SYSTEM + Administrators (the Windows counterpart of chmod 0600).')
    $lines.Add(('set "CLICKEYE_PROJECT={0}"'            -f (ConvertTo-CmdValue $Cfg.Project)))
    $lines.Add(('set "CLICKEYE_CLOUD_URL={0}"'          -f (ConvertTo-CmdValue $Cfg.CloudUrl)))
    $lines.Add(('set "CLICKEYE_CLOUD_TOKEN={0}"'        -f (ConvertTo-CmdValue $Cfg.Token)))
    $lines.Add('set "CLICKEYE_REQUIRE_CLOUD=true"')
    $lines.Add(('set "CLICKEYE_DATA_DIR={0}"'           -f (ConvertTo-CmdValue $Paths.DataDir)))
    $lines.Add(('set "CLICKEYE_WORKSPACE_DIR={0}"'      -f (ConvertTo-CmdValue $Paths.WorkDir)))
    $lines.Add(('set "CLICKEYE_LOCAL_API=127.0.0.1:{0}"' -f $Port))
    $lines.Add(('set "CLICKEYE_DAEMON_ID={0}"'          -f (ConvertTo-CmdValue $DaemonIdValue)))
    # AI CLI 자격 — **지정된 쪽만** 쓴다(sh 와 같은 판단): 빈 값으로 써 두면 CLI 가
    # "설정됐지만 비어 있다"로 읽어 인증 실패 메시지가 달라지고 원인을 찾기 어려워진다.
    if (-not [string]::IsNullOrEmpty($Cfg.AnthropicKey)) {
        $lines.Add(('set "ANTHROPIC_API_KEY={0}"'       -f (ConvertTo-CmdValue $Cfg.AnthropicKey)))
    }
    if (-not [string]::IsNullOrEmpty($Cfg.OauthToken)) {
        $lines.Add(('set "CLAUDE_CODE_OAUTH_TOKEN={0}"' -f (ConvertTo-CmdValue $Cfg.OauthToken)))
    }
    $lines.Add(('cd /d "{0}"'                           -f $Paths.ProjDir))
    $lines.Add(('"{0}"'                                 -f $Paths.BinDst))

    # ASCII·BOM 없음으로 쓴다. .cmd 선두에 BOM 이 있으면 cmd.exe 가 첫 줄을 명령으로
    # 해석하려다 실패한다. 그래서 이 파일의 주석은 전부 ASCII 다.
    $text = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Paths.Launcher, $text, (New-Object System.Text.ASCIIEncoding))
}

function ConvertTo-CmdValue {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return $Value.Replace('%', '%%')
}

# ---------- 설치 ----------
function Invoke-Install {
    param([hashtable]$Cfg, [hashtable]$Paths)

    # ---------- 1. 전제 검사 ----------
    Assert-Administrator

    # 5.1 이 최저선이다 ([W1]). 그보다 낮은 호스트(2008 R2 의 2.0 등)는 여기서 걸린다.
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Stop-Install ('PowerShell 5.1 이상이 필요합니다 (현재: {0}) — Windows Management Framework 5.1 을 설치하세요' -f $PSVersionTable.PSVersion)
    }
    if ($null -eq (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        Stop-Install '작업 스케줄러 cmdlet(ScheduledTasks 모듈)이 없습니다 — Windows 8 / Server 2012 이상이 필요합니다'
    }

    # Agent CLI — claude 또는 codex 중 최소 하나. 둘 다 없으면 잡을 실행할 수단이 없다.
    $agentClis = @()
    if ($null -ne (Get-Command claude -ErrorAction SilentlyContinue)) { $agentClis += 'claude' }
    if ($null -ne (Get-Command codex  -ErrorAction SilentlyContinue)) { $agentClis += 'codex' }
    if ($agentClis.Count -eq 0) {
        Stop-Install @'
Agent CLI 가 없습니다 — claude 또는 codex 중 최소 하나가 PATH 에 있어야 합니다
  데몬이 잡을 실행할 수단이 없으므로 설치를 중단합니다.
  설치: npm install -g @anthropic-ai/claude-code  (또는 codex CLI)
'@
    }

    # git·Node 는 **기동 차단 사유가 아니다**(경고로 낮춘다) — sh 와 같은 판단.
    # 근거: 무엇이 빠졌는지는 데몬이 접속 시 관제로 올려(daemon.hello.env) 콘솔이 한자리에서
    # 보여준다. 설치 시점에 호스트마다 막아 세우는 것보다, 일단 붙여 놓고 콘솔에서
    # 환경 미비를 한눈에 확인·보강하는 편이 운영 부담이 낮다.
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warn 'git 이 없습니다 — 잡 작업공간 provisioning 이 실패합니다. 설치를 계속하되 보강하세요 (winget install Git.Git)'
        Write-Warn '  (부재 사실은 데몬이 접속 시 관제 콘솔에 환경 리포트로 올립니다)'
    }
    $nodeDesc = 'none'
    if ($null -eq (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Warn 'Node.js 가 없습니다 — Node 기반 AI CLI 실행에 필요합니다(권장 22+). 설치를 계속하되 보강하세요'
        Write-Warn '  (부재 사실은 데몬이 접속 시 관제 콘솔에 환경 리포트로 올립니다)'
    } else {
        $nodeDesc = [string](& node -v 2>$null)
        if ([string]::IsNullOrEmpty($nodeDesc)) { $nodeDesc = 'unknown' }
        $m = [regex]::Match($nodeDesc, '^v?(\d+)')
        if (-not $m.Success) {
            Write-Warn ("node -v 출력을 해석할 수 없습니다: '{0}'" -f $nodeDesc)
        } elseif ([int]$m.Groups[1].Value -lt 22) {
            Write-Warn ('Node.js 22 이상을 권장합니다 (현재: {0}) — 설치는 계속합니다' -f $nodeDesc)
        }
    }

    if ([string]::IsNullOrEmpty($Cfg.CloudUrl)) {
        Show-Usage
        Stop-Install '-CloudUrl (또는 CLICKEYE_CLOUD_URL) 이 필요합니다 — Cloud WS 주소 (wss://<host>/ws/daemon)'
    }
    if ([string]::IsNullOrEmpty($Cfg.Token)) {
        Show-Usage
        Stop-Install '-Token (또는 CLICKEYE_CLOUD_TOKEN) 이 필요합니다 — 관제 콘솔의 데몬 토큰 화면에서 발급'
    }

    # ---------- 2. 바이너리 소스 확보 ----------
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('clickeye-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $binSrc = ''
        if ($Cfg.SrcKind -eq 'binary') {
            if (-not [string]::IsNullOrEmpty($Cfg.Binary)) {
                $binSrc = $Cfg.Binary
            } else {
                $binSrc = Join-Path $Cfg.ScriptDir 'daemond.exe'
            }
            if (-not (Test-Path -LiteralPath $binSrc -PathType Leaf)) {
                Stop-Install ('데몬 바이너리를 찾을 수 없습니다: {0} — 스크립트 옆에 daemond.exe 를 두거나 -Binary/-Zip/-Git 로 지정하세요' -f $binSrc)
            }
            Write-Info ('설치 소스: 로컬 바이너리 {0}' -f $binSrc)
        } elseif ($Cfg.SrcKind -eq 'zip') {
            $archive = ''
            if ($Cfg.Zip -match '^https?://') {
                $name = 'pkg.zip'
                if ($Cfg.Zip -match '\.(tar\.gz|tgz)$') { $name = 'pkg.tar.gz' }
                $archive = Join-Path $tmp $name
                Write-Info ('설치 소스: 아카이브 URL {0}' -f $Cfg.Zip)
                Save-Download -Url $Cfg.Zip -OutFile $archive
            } else {
                if (-not (Test-Path -LiteralPath $Cfg.Zip -PathType Leaf)) {
                    Stop-Install ('아카이브를 찾을 수 없습니다: {0}' -f $Cfg.Zip)
                }
                $archive = (Resolve-Path -LiteralPath $Cfg.Zip).Path
                Write-Info ('설치 소스: 로컬 아카이브 {0}' -f $archive)
            }
            if (-not [string]::IsNullOrEmpty($Cfg.Sha256)) {
                Assert-Checksum -File $archive -Expected $Cfg.Sha256
            } else {
                Write-Warn '체크섬이 지정되지 않았습니다 — 아카이브 무결성 검증을 건너뜁니다'
                Write-Warn '  신뢰할 수 없는 경로로 받았다면 -Sha256 <값|파일> 로 검증하세요'
            }
            $binSrc = Join-Path $tmp 'daemond.exe'
            Expand-DaemonArchive -Archive $archive -Destination $binSrc -TempDir $tmp
        } else {
            Write-Info ('설치 소스: git {0}' -f $Cfg.Git)
            $binSrc = Join-Path $tmp 'daemond.exe'
            Build-FromGit -RepoUrl $Cfg.Git -Ref $Cfg.GitRef -Destination $binSrc -TempDir $tmp
        }

        $port = Get-AllocatedPort -Name $Cfg.Project -SelfLauncher $Paths.Launcher `
            -Root $Cfg.BaseDir -Launcher $Cfg.LauncherName -Base $Cfg.PortBase -Span $Cfg.PortSpan

        $daemonIdValue = $Cfg.DaemonId
        if ([string]::IsNullOrEmpty($daemonIdValue)) {
            # 한 호스트에 데몬이 여러 개 뜨므로 hostname 만으로는 중복된다 — 프로젝트를 붙인다.
            $daemonIdValue = '{0}-{1}' -f $env:COMPUTERNAME, $Cfg.Project
        }

        Write-Info ('전제 검사 통과 (project={0}, powershell={1}, agent-cli={2}, node={3})' -f `
            $Cfg.Project, $PSVersionTable.PSVersion, ($agentClis -join ', '), $nodeDesc)

        # ---------- 3. 환경 세팅 → 데몬 배치 (멱등) ----------
        # 3-1) 프로젝트 디렉터리. ACL 로 SYSTEM+Administrators 만 남긴다 ([W4]) —
        #      sh 의 0750 + 전용 사용자 소유에 대응하는, Windows 에서 달성 가능한 보호다.
        New-Item -ItemType Directory -Path $Paths.DataDir -Force | Out-Null
        New-Item -ItemType Directory -Path $Paths.WorkDir -Force | Out-Null
        Set-RestrictedAcl -Path $Paths.ProjDir -System $Cfg.SidSystem -Admins $Cfg.SidAdmins -Container
        Write-Info ('프로젝트 디렉터리: {0} (data, workspaces / ACL: SYSTEM+Administrators)' -f $Paths.ProjDir)

        # 3-2) 바이너리 — 이 작업이 실행 중이면 정지 후 교체 (업그레이드 경로).
        #      다른 프로젝트의 작업은 건드리지 않는다.
        if ($null -ne (Get-DaemonTask -TaskName $Paths.TaskName -Folder $Cfg.TaskFolder)) {
            Write-Info ('실행 중인 작업 정지 (바이너리 교체를 위해): {0}{1}' -f $Cfg.TaskFolder, $Paths.TaskName)
            Stop-DaemonAndWait -TaskName $Paths.TaskName -Folder $Cfg.TaskFolder -BinPath $Paths.BinDst
        }
        Copy-Item -LiteralPath $binSrc -Destination $Paths.BinDst -Force
        Write-Info ('바이너리 배치: {0}' -f $Paths.BinDst)

        # 3-3) 런처 (토큰이 들어간다 — ACL 잠금. 기존 파일은 백업 후 갱신) [W3]
        if (Test-Path -LiteralPath $Paths.Launcher) {
            $backup = '{0}.bak.{1}' -f $Paths.Launcher, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $Paths.Launcher -Destination $backup -Force
            Set-RestrictedAcl -Path $backup -System $Cfg.SidSystem -Admins $Cfg.SidAdmins
            Write-Info ('기존 런처 백업: {0}' -f $backup)
        }
        Write-DaemonLauncher -Cfg $Cfg -Paths $Paths -Port $port -DaemonIdValue $daemonIdValue
        Write-Info ('런처 작성: {0} (ACL: SYSTEM+Administrators 만, localapi=127.0.0.1:{1})' -f $Paths.Launcher, $port)

        # ---------- 4. 작업 등록 + 기동 + 검증 ----------
        if ($Cfg.NoStart) {
            Write-Info '──────────────────────────────────────────────'
            Write-Info ("완료 (-NoStart): 프로젝트 '{0}' 파일 배치까지 끝났습니다." -f $Cfg.Project)
            Write-Info '  작업 스케줄러 등록과 기동은 하지 않았습니다 ([W8]) — 등록하려면 -NoStart 없이 같은 명령을 다시 실행하세요.'
            return
        }

        Register-DaemonTask -Cfg $Cfg -Paths $Paths
        Write-Info ('작업 등록: {0}{1} (SYSTEM / 부팅 시 실행 / 1분 반복 감시)' -f $Cfg.TaskFolder, $Paths.TaskName)

        Start-ScheduledTask -TaskPath $Cfg.TaskFolder -TaskName $Paths.TaskName
        Write-Info ('작업 시작 — localapi 응답 대기 (최대 {0}초)' -f $Cfg.HealthTries)

        $statusUrl = 'http://127.0.0.1:{0}/api/status' -f $port
        for ($i = 0; $i -lt $Cfg.HealthTries; $i++) {
            if (Test-DaemonStatus -Url $statusUrl) {
                Write-Info '──────────────────────────────────────────────'
                Write-Info ('설치 성공: {0}{1} 기동 확인 ({2} 응답)' -f $Cfg.TaskFolder, $Paths.TaskName, $statusUrl)
                Write-Info ("다음 확인: 관제 콘솔 데몬 목록에 프로젝트 '{0}' 가 온라인으로 표시되는지" -f $Cfg.Project)
                Write-Info '  (git·Node·AI CLI 등 환경 미비는 콘솔의 데몬 환경 리포트에서 확인합니다)'
                return
            }
            Start-Sleep -Seconds 1
        }

        # 여기까지 왔으면 파일 배치는 끝났고 기동/응답만 실패한 것 — 어디를 볼지 먼저 알린 뒤 중단한다.
        Write-Warn '──────────────────────────────────────────────'
        Write-Warn '어디를 볼지:'
        Write-Warn ('  1) 작업 기록  : Get-ScheduledTaskInfo -TaskPath "{0}" -TaskName "{1}"' -f $Cfg.TaskFolder, $Paths.TaskName)
        Write-Warn '                  (LastTaskResult 가 0 이 아니면 작업이 시작조차 못 한 것)'
        Write-Warn '  2) 이벤트 로그: Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -MaxEvents 20'
        Write-Warn '                  (채널이 꺼져 있으면 이벤트 뷰어에서 "로그 사용" 후 재시도)'
        Write-Warn ('  3) 직접 실행  : cmd /c "{0}"   ← 데몬의 표준출력을 그 자리에서 본다' -f $Paths.Launcher)
        Write-Warn '(토큰/URL 오류로 인한 fail-closed 기동 거부가 가장 흔한 원인 — 가이드 §7)'
        Stop-Install ('설치 실패: {0} 이 {1}초 안에 응답하지 않았습니다 (위 안내 참조)' -f $statusUrl, $Cfg.HealthTries)
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- main ----------
# 전체 흐름을 함수로 감싼다 — 파이프 실행에서 다운로드가 중간에 끊기면 본문이 부분
# 실행되는 사고를 막는다. PowerShell 은 sh 보다 강하게 막아 준다: 잘린 스크립트는
# [scriptblock]::Create() 단계에서 파서 오류로 통째로 거부되므로 아예 실행되지 않는다.
function Invoke-Main {
    param([hashtable]$Cfg, [hashtable]$Bound)

    if ($Cfg.Help) { Show-Usage; return }

    # 설치 전용 인자가 하나라도 왔는가 — -Uninstall 과의 혼용 거부용 (sh 의 INSTALL_ARGS).
    # 환경변수 폴백은 여기 세지 않는다: sh 도 플래그로 온 것만 센다.
    $installArgs = $false
    foreach ($n in @('CloudUrl', 'Token', 'Binary', 'Zip', 'Sha256', 'Git', 'GitRef', 'DaemonId', 'NoStart')) {
        if ($Bound.ContainsKey($n)) { $installArgs = $true }
    }

    # ---------- 프로젝트 (설치·철거 공통 필수) ----------
    # sh 와 같은 순서: 이름 검증이 권한 검사보다 먼저다. 잘못 친 이름은 관리자 콘솔을
    # 새로 띄우기 전에 알려 주는 편이 낫다.
    Assert-ValidProject -Name $Cfg.Project
    $paths = Get-ProjectPaths -Name $Cfg.Project -Root $Cfg.BaseDir -Launcher $Cfg.LauncherName -Prefix $Cfg.TaskPrefix

    # ---------- 철거 분기 ----------
    if ($Cfg.PurgeData -and (-not $Cfg.Uninstall)) {
        Show-Usage
        Stop-Install '-PurgeData 는 -Uninstall 과 함께만 쓸 수 있습니다'
    }
    if ($Cfg.Uninstall) {
        if ($installArgs) {
            Show-Usage
            Stop-Install '-Uninstall 은 설치 인자(-CloudUrl/-Token/-Binary/-Zip/-Git/-DaemonId/-NoStart)와 함께 쓸 수 없습니다'
        }
        Invoke-Uninstall -Cfg $Cfg -Paths $paths
        return
    }

    # ---------- 소스 옵션 배타 검사 ----------
    $srcCount = 0
    if ($Bound.ContainsKey('Binary')) { $srcCount++ }
    if ($Bound.ContainsKey('Zip'))    { $srcCount++ }
    if ($Bound.ContainsKey('Git'))    { $srcCount++ }
    if ($srcCount -gt 1) {
        Show-Usage
        Stop-Install ('설치 소스는 하나만 지정하세요 — -Binary / -Zip / -Git 중 택 1 (지정된 개수: {0})' -f $srcCount)
    }
    if ($Bound.ContainsKey('Sha256') -and $Cfg.SrcKind -ne 'zip') {
        Stop-Install '-Sha256 은 -Zip 과 함께만 쓸 수 있습니다'
    }
    if ($Bound.ContainsKey('GitRef') -and $Cfg.SrcKind -ne 'git') {
        Stop-Install '-GitRef 는 -Git 과 함께만 쓸 수 있습니다'
    }
    if ($Bound.ContainsKey('AnthropicKey') -and $Bound.ContainsKey('OauthToken')) {
        Show-Usage
        Stop-Install 'AI CLI 자격은 하나만 지정하세요 — -AnthropicKey 와 -OauthToken 은 함께 쓸 수 없습니다'
    }

    Invoke-Install -Cfg $Cfg -Paths $paths
}

# ---------- 진입점 ----------
# 자동 변수는 파이프 실행(scriptblock)에서 정의되지 않을 수 있다. StrictMode 아래에서는
# 미정의 참조가 예외이므로 try 로 감싸 빈 값으로 떨어뜨린다.
$scriptPath = ''
try { if ($null -ne $PSCommandPath) { $scriptPath = [string]$PSCommandPath } } catch { $scriptPath = '' }
$scriptDir = ''
try { if ($null -ne $PSScriptRoot) { $scriptDir = [string]$PSScriptRoot } } catch { $scriptDir = '' }
# 파이프 실행에서는 sh 에서 $0=sh 일 때 dirname 이 "." 이 되는 것과 같이 현재 디렉터리가 기본이 된다.
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = (Get-Location).Path }

$bound = @{}
try { foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = $true } } catch { $bound = @{} }

# 환경변수 폴백 (플래그가 우선) — sh 와 같은 세 개.
$effCloudUrl = $CloudUrl
$effToken    = $Token
$effDaemonId = $DaemonId
if ([string]::IsNullOrEmpty($effCloudUrl) -and -not [string]::IsNullOrEmpty($env:CLICKEYE_CLOUD_URL))   { $effCloudUrl = $env:CLICKEYE_CLOUD_URL }
if ([string]::IsNullOrEmpty($effToken)    -and -not [string]::IsNullOrEmpty($env:CLICKEYE_CLOUD_TOKEN)) { $effToken    = $env:CLICKEYE_CLOUD_TOKEN }
if ([string]::IsNullOrEmpty($effDaemonId) -and -not [string]::IsNullOrEmpty($env:CLICKEYE_DAEMON_ID))   { $effDaemonId = $env:CLICKEYE_DAEMON_ID }

$srcKind = 'binary'
if ($bound.ContainsKey('Zip')) { $srcKind = 'zip' }
if ($bound.ContainsKey('Git')) { $srcKind = 'git' }

# 파라미터를 해시테이블 하나로 모아 인자로만 내려보낸다 ([W9]).
$cfg = @{
    Project      = $Project
    CloudUrl     = $effCloudUrl
    Token        = $effToken
    Binary       = $Binary
    Zip          = $Zip
    Sha256       = $Sha256
    Git          = $Git
    GitRef       = $GitRef
    DaemonId     = $effDaemonId
    AnthropicKey = $AnthropicKey
    OauthToken   = $OauthToken
    NoStart      = [bool]$NoStart
    Uninstall    = [bool]$Uninstall
    PurgeData    = [bool]$PurgeData
    Help         = [bool]$Help
    SrcKind      = $srcKind
    ScriptDir    = $scriptDir
    BaseDir      = $BaseDir
    TaskFolder   = $TaskFolder
    TaskPrefix   = $TaskPrefix
    LauncherName = $LauncherName
    HealthTries  = $HealthTries
    PortBase     = $PortBase
    PortSpan     = $PortSpan
    SidSystem    = $SidSystem
    SidAdmins    = $SidAdmins
}

$exitCode = 0
try {
    Invoke-Main -Cfg $cfg -Bound $bound | Out-Null
} catch {
    $msg = [string]$_.Exception.Message
    if (-not $msg.StartsWith('[install]')) { $msg = '[install] 오류: ' + $msg }
    [Console]::Error.WriteLine($msg)
    $exitCode = 1
}

# 파일 실행이면 종료 코드를 세우고 끝낸다. 파이프 실행(scriptblock)에서 exit 를 부르면
# 운영자의 관리자 콘솔 자체가 닫히므로 $LASTEXITCODE 만 남긴다 ([W9]).
if (-not [string]::IsNullOrEmpty($scriptPath)) { exit $exitCode }
$global:LASTEXITCODE = $exitCode
