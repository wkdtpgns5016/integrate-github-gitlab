# integrate-github-gitlab

GitHub 레포를 GitLab(자체 호스팅)에 자동으로 미러링하도록 연동을 자동화하는 프로젝트입니다.
GitHub Actions가 push를 받으면 Tailscale로 GitLab에 접속해 `git push --force`로 미러링하고,
GitLab 쪽 CI는 자체 등록된 GitLab Runner(Docker executor)가 처리합니다.

## 구성

- [gitlab/](gitlab) — GitLab CE + GitLab Runner를 한 VM(호스트)에 docker-compose로 띄우고,
  빈 프로젝트 생성부터 러너 등록, GitHub 시크릿/변수 등록까지 전부 자동화하는 스크립트.
- [.github/workflows/mirror-to-gitlab.yml](.github/workflows/mirror-to-gitlab.yml) — main 브랜치 push 시
  Tailscale로 GitLab에 접속해 미러링하는 GitHub Actions 워크플로.

## 빈 VM에서 처음 시작하는 방법

### 0) 미리 준비해둘 것
- **GitHub PAT** — classic이면 `repo` 스코프, fine-grained면 대상 레포에 Contents(Read)/Secrets(RW)/Variables(RW) 권한.
- **Tailscale auth key 2개** (https://login.tailscale.com/admin/settings/keys)
  - `TAILSCALE_HOST_AUTHKEY`: 이 VM 자신을 tailnet에 조인시킬 때 사용. **Ephemeral은 꺼서** 발급.
  - `TS_AUTHKEY`: GitHub Actions가 매 실행마다 임시로 tailnet에 접속할 때 사용. **Ephemeral + Reusable을 켜서** 발급.
- 미러링 대상 **GitHub 레포** (`owner/repo`).

### 1) 패키지 설치 (Ubuntu/Debian 기준)

```bash
# Docker Engine + Compose 플러그인
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER" && newgrp docker   # 재로그인 없이 docker 그룹 적용

# jq, curl (대부분 기본 포함이지만 확인 차 설치)
sudo apt-get update -qq && sudo apt-get install -y jq curl

# GitHub CLI(gh)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt-get update -qq && sudo apt-get install -y gh
```

Tailscale은 따로 설치하지 않아도 됩니다 — `up.sh`가 [gitlab/script/setup-tailscale.sh](gitlab/script/setup-tailscale.sh)를
통해 없으면 자동으로 설치하고 조인까지 처리합니다.

### 2) 환경변수 설정

```bash
git clone <이 레포 URL>
cd integrate-github-gitlab/gitlab
cp .env.example .env
```

`.env`를 열어 최소한 아래 값을 채웁니다 (나머지는 [.env.example](gitlab/.env.example) 주석 참고):

- `GITHUB_REPO`, `GITHUB_PAT`
- `GITLAB_ROOT_PASSWORD`
- `TAILSCALE_HOST_AUTHKEY`, `TS_AUTHKEY`
- `GITLAB_HOST`는 비워둬도 됩니다 — `TAILSCALE_HOST_AUTHKEY`를 채웠다면 `up.sh`가 Tailscale IP로 자동 채웁니다.

### 3) 미러링할 레포에 워크플로 복사

`.github/workflows/mirror-to-gitlab.yml`은 **미러링 대상 레포(`GITHUB_REPO`)**에 있어야 실행됩니다.
`GITHUB_REPO`가 이 스캐폴딩 레포 자신이 아니라 별도의 기존 레포라면, 이 레포의 `.github/` 디렉토리를
그대로 복사해서 대상 레포에 붙여넣고 커밋/푸시하세요.

```bash
cp -r .github <대상 레포 경로>/
cd <대상 레포 경로>
git add .github && git commit -m "Add GitLab mirroring workflow" && git push
```

### 4) 실행

```bash
./up.sh
```

내부적으로 다음 순서로 진행됩니다: 의존성/GitHub 인증 사전 점검 → Tailscale 설치·조인 →
`docker compose up -d` → GitLab 컨테이너 `healthy` 대기 → 빈 프로젝트 생성 → 러너 등록 →
미러링용 access token 발급 → GitHub 시크릿/변수 등록. 최초 기동은 GitLab 특성상 수 분 걸립니다.

### 5) 검증

- 로그 마지막에 출력되는 `http://<GITLAB_HOST>:<PORT>/root/<프로젝트명>` 접속 확인
  (`root` / `.env`의 `GITLAB_ROOT_PASSWORD`).
- 시크릿/변수가 실제로 등록됐는지 CLI로 재확인:
  ```bash
  gh secret list --repo owner/repo
  gh variable list --repo owner/repo
  ```
- GitHub 레포의 main 브랜치에 push(또는 Actions 탭에서 workflow_dispatch)해서
  [mirror-to-gitlab.yml](.github/workflows/mirror-to-gitlab.yml)이 GitLab으로 정상 미러링되는지 확인.

### 주의할 점

- `up.sh`/`bootstrap-gitlab.sh`는 여러 번 실행해도 안전(idempotent)합니다. 다만 미러링용 project
  access token은 재실행할 때마다 재발급되어 GitHub 시크릿이 매번 갱신됩니다.
- [docker-compose.yml](gitlab/docker-compose.yml)의 포트 매핑은 `0.0.0.0`에 바인딩됩니다. VM에 공인 IP가
  있다면 Tailscale 인터페이스뿐 아니라 공인 인터페이스로도 노출되니, 보안그룹/방화벽에서 해당 포트를
  공인 IP 쪽에서는 막아두세요 (Tailscale 자체는 터널링이라 별도 인바운드 규칙이 필요 없습니다).
