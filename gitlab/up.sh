#!/usr/bin/env bash
# GitLab + Runner 를 띄우고, GitLab 이 healthy 가 되면 bootstrap-gitlab.sh 를 실행한다.
#   docker compose up -d → GitLab healthy 대기 → 프로젝트/러너/GitHub 시크릿·변수 등록
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

log() { printf '\033[1;34m[up]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[up] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE 가 없습니다. 'cp gitlab/.env.example gitlab/.env' 후 값을 채우세요."

# .env 에는 GITHUB_PAT/GITLAB_ROOT_PASSWORD 등 민감한 값이 평문으로 들어있으므로,
# cp 로 생성될 때 물려받는 기본 권한(보통 644, world-readable)을 소유자 전용으로 좁힌다.
chmod 600 "$ENV_FILE"

set -a; source "$ENV_FILE"; set +a

for cmd in docker gh jq curl; do
  command -v "$cmd" >/dev/null || die "'$cmd' 가 필요합니다."
done
docker info >/dev/null 2>&1 || die "Docker 데몬에 연결할 수 없습니다."

# gh 는 GH_TOKEN(또는 GITHUB_TOKEN) 환경변수가 있으면 자동으로 그 토큰을 사용한다.
# .env 의 GITHUB_PAT 를 GH_TOKEN 으로 노출시켜 'gh auth login' 을 생략한다.
[[ -n "${GITHUB_PAT:-}" ]] || die "GITHUB_PAT 가 .env 에 없습니다."
export GH_TOKEN="$GITHUB_PAT"

# 10분 넘게 걸리는 GitLab 기동 뒤에 실패하지 않도록 인증/설정 오류는 먼저 확인한다.
gh auth status >/dev/null 2>&1 || die "GITHUB_PAT 로 인증할 수 없습니다. 토큰 값/권한을 확인하세요."
[[ -n "${GITHUB_REPO:-}" ]] || die "GITHUB_REPO 가 .env 에 없습니다."
gh repo view "$GITHUB_REPO" >/dev/null 2>&1 || die "GitHub 레포 '$GITHUB_REPO' 에 접근할 수 없습니다."

# TAILSCALE_HOST_AUTHKEY 가 있으면 이 머신을 tailnet 에 조인시키고 GITLAB_HOST 를 자동으로 채운다.
# (비어 있으면 setup-tailscale.sh 가 조용히 건너뜀 — 로컬 전용 검증에는 영향 없음)
"$SCRIPT_DIR/script/setup-tailscale.sh"
set -a; source "$ENV_FILE"; set +a  # GITLAB_HOST 가 갱신됐을 수 있으므로 다시 읽는다

log "docker compose up -d"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

log "GitLab healthy 대기 중 (최초 기동은 수 분 걸립니다)"
timeout="${GITLAB_WAIT_TIMEOUT:-1200}"
start=$SECONDS
while true; do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' gitlab 2>/dev/null || echo missing)"
  [[ "$status" == "healthy" ]] && break
  [[ "$status" == "missing" || "$status" == "no-healthcheck" ]] && die "gitlab 컨테이너 상태 이상: $status"
  (( SECONDS - start < timeout )) || die "${timeout}s 안에 healthy 가 되지 않았습니다. docker logs gitlab 을 확인하세요."
  printf '  ... %s (%ss)\n' "$status" "$((SECONDS - start))"
  sleep 10
done
log "GitLab healthy"

exec "$SCRIPT_DIR/script/bootstrap-gitlab.sh"