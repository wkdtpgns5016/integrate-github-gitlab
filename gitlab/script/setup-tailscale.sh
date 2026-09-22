#!/usr/bin/env bash
# 이 머신에 Tailscale 을 설치하고(없으면) tailnet 에 조인시킨 뒤,
# 이 머신의 Tailscale IP 를 gitlab/.env 의 GITLAB_HOST 에 자동으로 채워넣는다.
# macOS(Homebrew) / Linux(공식 설치 스크립트) 를 자동 감지한다.
# TAILSCALE_HOST_AUTHKEY 가 비어 있으면 아무것도 하지 않고 조용히 종료한다 (opt-in).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

log() { printf '\033[1;36m[tailscale]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[tailscale] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE 가 없습니다."
set -a; source "$ENV_FILE"; set +a

[[ -n "${TAILSCALE_HOST_AUTHKEY:-}" ]] || { log "TAILSCALE_HOST_AUTHKEY 가 비어 있어 건너뜁니다."; exit 0; }

# 이미 root 로 실행 중이면 sudo 를 붙이지 않는다.
# (root 는 pam_rootok 덕에 어차피 암호를 안 묻지만, sudo 자체가 없는 최소 구성 환경/컨테이너도 있어서 안전하게 처리)
SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "root 가 아니고 sudo 도 없습니다. root 로 실행하거나 sudo 를 설치하세요."
  SUDO="sudo"
fi

# ── 1) 설치 ───────────────────────────────────────────────
if ! command -v tailscale >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null 2>&1 || die "Homebrew 가 필요합니다: https://brew.sh"
      log "Homebrew 로 tailscale 설치"
      brew install tailscale
      log "tailscaled 서비스 시작${SUDO:+ (관리자 암호 필요)}"
      $SUDO brew services start tailscale
      ;;
    Linux)
      log "공식 설치 스크립트로 tailscale 설치${SUDO:+ (관리자 암호 필요할 수 있음)}"
      curl -fsSL https://tailscale.com/install.sh | sh
      command -v systemctl >/dev/null 2>&1 && $SUDO systemctl enable --now tailscaled
      ;;
    *)
      die "지원하지 않는 OS 입니다: $(uname -s). tailscale 을 직접 설치한 뒤 다시 실행하세요."
      ;;
  esac
else
  log "tailscale 이미 설치됨"
fi

command -v tailscale >/dev/null 2>&1 || die "tailscale 설치에 실패했습니다."

# ── 2) tailscaled 준비 대기 ────────────────────────────────
for _ in $(seq 1 15); do
  $SUDO tailscale status >/dev/null 2>&1 && break
  sleep 1
done

# ── 3) 조인 (이미 로그인돼 있으면 건너뜀) ───────────────────
state="$($SUDO tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')"
if [[ "$state" == "Running" ]]; then
  log "이미 tailnet 에 조인되어 있음"
else
  log "tailnet 조인 중${SUDO:+ (관리자 암호 필요할 수 있음)}"
  $SUDO tailscale up --authkey="$TAILSCALE_HOST_AUTHKEY" --accept-routes
fi

# ── 4) IP 확인 및 GITLAB_HOST 자동 입력 ─────────────────────
ip=""
for _ in $(seq 1 15); do
  ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  [[ -n "$ip" ]] && break
  sleep 1
done
[[ -n "$ip" ]] || die "Tailscale IP 를 확인하지 못했습니다. 'tailscale status' 로 상태를 확인하세요."
log "Tailscale IP: $ip"

python3 - "$ENV_FILE" "$ip" <<'PY'
import re, sys
path, ip = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
text = re.sub(r'(?m)^GITLAB_HOST=.*$', f'GITLAB_HOST={ip}', text, count=1)
with open(path, 'w') as f:
    f.write(text)
PY
log "gitlab/.env 의 GITLAB_HOST 를 $ip 로 갱신"
