#!/usr/bin/env bash
# healthy 상태의 GitLab 에 대해:
#   1) 빈 프로젝트 생성 (이미 있으면 재사용)
#   2) 러너 생성 + gitlab-runner 컨테이너에 등록
#   3) 미러링용 project access token 발급
#   4) GitHub Actions 에 필요한 시크릿/변수를 gh 로 등록
# 여러 번 실행해도 안전하다. (단, access token 은 실행할 때마다 재발급되어 GitHub 시크릿이 갱신됨)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

GITLAB_CONTAINER=gitlab
RUNNER_CONTAINER=gitlab-runner
# compose 네트워크 안에서의 GitLab 주소 (러너 → GitLab, job 컨테이너 → GitLab)
GITLAB_INTERNAL_URL=http://gitlab
DOCKER_NETWORK=gitlab-net
# project access token 으로 git push 할 때 사용자명은 임의 문자열이면 된다.
DEPLOY_USER=oauth2
TOKEN_NAME=github-mirror

log() { printf '\033[1;32m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[bootstrap] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE 가 없습니다."
set -a; source "$ENV_FILE"; set +a

for cmd in docker gh jq curl; do
  command -v "$cmd" >/dev/null || die "'$cmd' 가 필요합니다."
done
: "${GITHUB_REPO:?GITHUB_REPO 가 .env 에 없습니다}"
: "${GITLAB_HOST:?GITLAB_HOST 가 .env 에 없습니다}"
[[ "$GITHUB_REPO" == */* ]] || die "GITHUB_REPO 는 owner/repo 형식이어야 합니다: $GITHUB_REPO"

HTTP_PORT="${GITLAB_HTTP_PORT:-8088}"
# 호스트에서 접근하는 GitLab 주소 (docker-compose.yml 의 포트 매핑)
BASE_URL="http://localhost:$HTTP_PORT"
API="$BASE_URL/api/v4"
# GitHub Actions 가 push 할 때 쓰는 외부 주소. 워크플로가 http://$GITLAB_HOST/... 로 조립하므로 포트까지 포함한다.
PUBLIC_HOST="$GITLAB_HOST"
[[ "$HTTP_PORT" == 80 ]] || PUBLIC_HOST="$GITLAB_HOST:$HTTP_PORT"

PROJECT_NAME="${GITLAB_PROJECT_NAME:-${GITHUB_REPO#*/}}"
PROJECT_PATH="root/$PROJECT_NAME"
PROJECT_PATH_ENC="$(jq -rn --arg p "$PROJECT_PATH" '$p|@uri')"
RUNNER_NAME="${GITLAB_RUNNER_NAME:-$PROJECT_NAME-runner}"

# ── GitLab API 준비 확인 ─────────────────────────────────────
# 컨테이너 헬스체크(healthy)는 API(Puma)가 완전히 뜨기 전에도 통과할 수 있어서,
# API 가 유효한 JSON 을 반환하는지로 다시 확인한다 (버전 조회는 인증 없이도 유효한 JSON 을 반환함).
log "GitLab API 응답 확인 (최초 기동은 healthy 이후에도 수 분 더 걸릴 수 있습니다)"
ready_timeout="${GITLAB_WAIT_TIMEOUT:-1200}"
ready_start=$SECONDS
until curl -s "$API/version" | jq -e . >/dev/null 2>&1; do
  (( SECONDS - ready_start < ready_timeout )) || \
    die "${ready_timeout}s 안에 $API 가 유효한 응답을 반환하지 않았습니다. 'docker logs gitlab' 로 진행 상황을 확인하세요."
  printf '.'
  sleep 3
done
echo ""

# ── 임시 admin PAT 발급 (종료 시 폐기) ────────────────────────
# root 비밀번호에 의존하지 않도록 rails runner 로 직접 발급한다.
log "임시 root PAT 발급"
PAT="$(docker exec "$GITLAB_CONTAINER" gitlab-rails runner '
  user = User.find_by_username("root")
  user.personal_access_tokens.where(name: "bootstrap").each(&:revoke!)
  token = user.personal_access_tokens.create!(
    name: "bootstrap",
    scopes: [:api, :create_runner],
    expires_at: 1.day.from_now
  )
  puts "PAT=#{token.token}"
' | sed -n 's/^PAT=//p')"
[[ -n "$PAT" ]] || die "PAT 발급 실패"
trap 'curl -sS -o /dev/null -X DELETE -H "PRIVATE-TOKEN: $PAT" "$API/personal_access_tokens/self" || true' EXIT

api() { # api METHOD PATH [curl 옵션...]  — 실패 시 응답 본문과 함께 종료
  local method="$1" path="$2"; shift 2
  curl -sS --fail-with-body -X "$method" -H "PRIVATE-TOKEN: $PAT" "$@" "$API$path"
}

# ── 1) 빈 프로젝트 ───────────────────────────────────────────
if project_json="$(curl -sS --fail-with-body -H "PRIVATE-TOKEN: $PAT" "$API/projects/$PROJECT_PATH_ENC" 2>/dev/null)"; then
  log "프로젝트 이미 존재: $PROJECT_PATH"
else
  log "빈 프로젝트 생성: $PROJECT_PATH"
  project_json="$(api POST /projects \
    --data-urlencode "name=$PROJECT_NAME" \
    --data-urlencode "path=$PROJECT_NAME" \
    --data-urlencode "visibility=private" \
    --data-urlencode "initialize_with_readme=false")"
fi
PROJECT_ID="$(jq -r .id <<<"$project_json")"

# 미러링은 `git push --force` 이므로 main 에 대해 force push 를 허용해 둔다.
# (빈 프로젝트에는 main 이 아직 없지만 protected branch 규칙은 미리 만들 수 있다.)
if api GET "/projects/$PROJECT_ID/protected_branches/main" >/dev/null 2>&1; then
  api PATCH "/projects/$PROJECT_ID/protected_branches/main" -d allow_force_push=true >/dev/null
else
  api POST "/projects/$PROJECT_ID/protected_branches" \
    -d name=main -d push_access_level=40 -d merge_access_level=40 -d allow_force_push=true >/dev/null
fi
log "main 브랜치 force push 허용"

# ── 2) 러너 ─────────────────────────────────────────────────
if docker exec "$RUNNER_CONTAINER" grep -qs "name = \"$RUNNER_NAME\"" /etc/gitlab-runner/config.toml; then
  log "러너 이미 등록됨: $RUNNER_NAME"
else
  log "러너 생성 및 등록: $RUNNER_NAME"
  runner_token="$(api POST /user/runners \
    --data-urlencode "runner_type=project_type" \
    --data-urlencode "project_id=$PROJECT_ID" \
    --data-urlencode "description=$RUNNER_NAME" \
    --data-urlencode "run_untagged=true" | jq -r .token)"
  [[ -n "$runner_token" && "$runner_token" != null ]] || die "러너 토큰 발급 실패"
  docker exec "$RUNNER_CONTAINER" gitlab-runner register --non-interactive \
    --url "$GITLAB_INTERNAL_URL" \
    --clone-url "$GITLAB_INTERNAL_URL" \
    --token "$runner_token" \
    --name "$RUNNER_NAME" \
    --executor docker \
    --docker-image alpine:latest \
    --docker-network-mode "$DOCKER_NETWORK"
fi

# ── 3) 미러링용 project access token ─────────────────────────
# 이미 발급된 토큰 값은 다시 조회할 수 없으므로 같은 이름의 기존 토큰을 폐기하고 재발급한다.
for id in $(api GET "/projects/$PROJECT_ID/access_tokens" | jq -r --arg n "$TOKEN_NAME" '.[] | select(.name==$n and .active) | .id'); do
  api DELETE "/projects/$PROJECT_ID/access_tokens/$id" >/dev/null
done
expires_at="$(date -u -v+300d +%F 2>/dev/null || date -u -d '+300 days' +%F)"
DEPLOY_TOKEN="$(api POST "/projects/$PROJECT_ID/access_tokens" \
  --data-urlencode "name=$TOKEN_NAME" \
  --data-urlencode "scopes[]=write_repository" \
  --data-urlencode "access_level=40" \
  --data-urlencode "expires_at=$expires_at" | jq -r .token)"
[[ -n "$DEPLOY_TOKEN" && "$DEPLOY_TOKEN" != null ]] || die "access token 발급 실패"
log "access token 발급 (만료: $expires_at)"

# ── 4) GitHub Actions 시크릿/변수 ────────────────────────────
log "GitHub($GITHUB_REPO) 시크릿/변수 등록"
set_secret() { printf '%s' "$2" | gh secret set "$1" --repo "$GITHUB_REPO" >/dev/null && echo "  secret   $1"; }
set_var()    { gh variable set "$1" --repo "$GITHUB_REPO" --body "$2" >/dev/null && echo "  variable $1=$2"; }

set_secret GITLAB_DEPLOY_USER  "$DEPLOY_USER"
set_secret GITLAB_DEPLOY_TOKEN "$DEPLOY_TOKEN"
if [[ -n "${TS_AUTHKEY:-}" ]]; then
  set_secret TS_AUTHKEY "$TS_AUTHKEY"
else
  log "TS_AUTHKEY 가 비어 있어 등록을 건너뜁니다. (워크플로가 필요로 하므로 나중에 직접 등록하세요)"
fi
set_var GITLAB_HOST         "$PUBLIC_HOST"
set_var GITLAB_PROJECT_PATH "$PROJECT_PATH"

log "완료 → http://$PUBLIC_HOST/$PROJECT_PATH  (root / .env 의 GITLAB_ROOT_PASSWORD)"
