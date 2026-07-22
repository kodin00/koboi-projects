#!/usr/bin/env bash
# quickstart.sh -- one-shot wizard to run any koboi-projects app end-to-end.
#
#   curl -fsSL https://raw.githubusercontent.com/hedypamungkas/koboi-projects/main/quickstart.sh | bash
#   (or:  bash quickstart.sh   from inside a checkout)
#
# Flow: preflight (Docker) -> clone/detect repo -> pick a project -> write .env
#       -> build & start (live progress) -> wait for health -> print URLs -> monitor.
#
# Cross-OS: native on macOS/Linux (bash 3.2-safe). Windows via WSL2 or Git Bash,
# or the companion quickstart.ps1 launcher (irm <url> | iex) which finds WSL/Git-Bash.
#
# Subcommands & flags (see --help): --project NAME [--yes] | --list | --status |
#   --logs NAME | --down NAME [--purge] | --update | --help | --no-color
# Env overrides: KOBOI_UC_REPO  KOBOI_UC_HOME  NO_COLOR=1  KOBOI_NO_UTF8=1

set -uo pipefail

# Pre-scan args for --no-color/--no-utf8 BEFORE colors/glyphs are baked in.
# Without this these flags are dead: the color/glyph init below runs before
# the dispatch loop ever sees them (P0-3).
for _a in "$@"; do
  case "$_a" in
    --no-color) export NO_COLOR=1 ;;
    --no-utf8)  export KOBOI_NO_UTF8=1 ;;
  esac
done
unset _a

# ───────────────────────────────── config ─────────────────────────────────
REPO_URL="${KOBOI_UC_REPO:-https://github.com/hedypamungkas/koboi-projects.git}"
REPO_HOME="${KOBOI_UC_HOME:-$HOME/koboi-projects}"
QHOME="$HOME/.koboi-quickstart"
LOG_DIR="$QHOME/logs"; LOCK_DIR="$QHOME/locks"
mkdir -p "$LOG_DIR" "$LOCK_DIR" || { echo "cannot create $QHOME (read-only HOME? set KOBOI_UC_HOME)." >&2; exit 1; }
HAVE_CURL=0   # set by preflight()
HEALTH_UNVERIFIED=0   # set by wait_health when it cannot probe (/healthz not checked)

# name|title|one-liner|backend_port   (frontend port = backend_port - 5000)
PROJECTS=(
"ecommerce-support|E-commerce support|Storefront chat: orders, returns, refunds|8001"
"hr-screening|HR screening|Overnight resume-scoring jobs|8002"
"finance-reconciliation|Finance reconciliation|Match invoices to POs; MCP to ERP|8003"
"healthcare-intake|Healthcare intake|Pre-visit symptom triage (RAG)|8004"
"legal-contract-review|Legal contract review|Clause-playbook redlining (Skills)|8005"
"real-estate|Real estate|Buyer chat + nightly listing drafts|8006"
"insurance-claims|Insurance claims triage|FNOL triage + self-healing|8007"
"market-intel|Market intelligence|Cited competitive briefs (deep research)|8008"
"employee-concierge|Employee concierge (A2A)|3-container cross-department A2A|8009"
"customer-success|Customer success|Account health + churn risk|8010"
)

# ─────────────────────────── colors + glyphs ──────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  ESC=$'\033'
  C_RED="${ESC}[31m"; C_GREEN="${ESC}[32m"; C_YELLOW="${ESC}[33m"
  C_CYAN="${ESC}[36m"; C_BOLD="${ESC}[1m"; C_DIM="${ESC}[2m"; R="${ESC}[0m"
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_DIM=""; R=""
fi
is_utf8() {
  [ "${KOBOI_NO_UTF8:-}" != "1" ] || return 1
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *UTF-8*|*utf-8*|*utf8*) return 0;; *) return 1;; esac
}
if is_utf8; then
  G_OK=✓ G_X=✗ G_STEP=▶ G_BUL=● G_DOT=○ G_ARR=→  BTl=┌ BTr=┐ BBl=└ BBr=┘ BH=─ BV=│
else
  G_OK=v G_X=x G_STEP=">" G_BUL="*" G_DOT="." G_ARR="->" BTl=+ BTr=+ BBl=+ BBr=+ BH=- BV="|"
fi

# ────────────────────────────── interactivity ─────────────────────────────
FORCE_NONINTERACTIVE=0
# Set by pick_project() -- it runs in the MAIN shell (not a subshell), so its
# die/exit terminates the whole script. Holds the project the user chose.
PICK_PROJECT=""
# Interactive only when not forced off, stdout is a terminal, and /dev/tty is a
# usable char device -- this is what keeps `curl ... | bash` interactive (stdin is
# the script pipe, but /dev/tty is still the user's terminal) while using
# defaults silently when headless (CI, --yes).
has_tty() { [ "$FORCE_NONINTERACTIVE" = "0" ] && [ -t 1 ] && [ -c /dev/tty ]; }

# ───────────────────────────────── helpers ────────────────────────────────
die()  { printf "\n${C_RED}${G_X} %s${R}\n" "$*" >&2; exit 1; }
warn() { printf "${C_YELLOW}! %s${R}\n" "$*" >&2; }
ok()   { printf "${C_GREEN}${G_OK} %s${R}\n" "$*"; }

STEP_N=0; STEP_T=0
set_total_steps() { STEP_T="$1"; STEP_N=0; }
step() { STEP_N=$((STEP_N+1)); printf "\n${C_BOLD}${C_CYAN}${G_STEP} [%s/%s] %s${R}\n" "$STEP_N" "$STEP_T" "$*"; }

# Animated spinner (tty) with live last-log-line; single quiet line when headless.
spinner() {
  local pid="$1" msg="$2" log="${3:-}" spin='|/-\' i=0 last=""
  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      if [ -n "$log" ] && [ -f "$log" ]; then last="$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' | cut -c1-58)"; fi
      printf "\r  ${C_CYAN}[%s]${R} ${C_DIM}%s${R}  ${C_DIM}%s   ${R}" "${spin:$((i%4)):1}" "$msg" "${last:+$G_ARR $last}"
      i=$((i+1)); sleep 0.3
    done
    printf "\r\033[K"
  else
    printf "  %s ...\n" "$msg"
    while kill -0 "$pid" 2>/dev/null; do sleep 1; done
  fi
}

prompt() {  # prompt "q" "default" -> echoes answer (default on Enter / headless)
  local q="$1" def="${2:-}" var=""
  if has_tty; then
    printf "%s%s " "${C_CYAN}?${R} ${C_BOLD}$q${R}" "${def:+ ${C_DIM}[$def]${R}}" >&2
    if ! { IFS= read -r var </dev/tty; } 2>/dev/null; then var=""; fi
  fi
  [ -n "$var" ] || var="$def"; echo "$var"
}
prompt_secret() {  # hidden typing
  local q="$1" var=""
  if has_tty; then
    printf "%s " "${C_CYAN}?${R} ${C_BOLD}$q${R}" >&2
    if ! { IFS= read -rs var </dev/tty; } 2>/dev/null; then var=""; fi
    printf "\n" >&2
  fi
  echo "$var"
}
mask() { local s="$1"; [ ${#s} -le 8 ] && { echo '****'; return; }; printf '%s...%s\n' "${s:0:4}" "${s: -4}"; }

box() {
  local l="$1"; local w=${#l}; local border
  border="$(printf "$BH%.0s" $(seq 1 $((w+2))))"
  printf "${C_CYAN}${BTl}%s${BTr}${R}\n" "$border"
  printf "${C_CYAN}${BV}${R} %s ${C_CYAN}${BV}${R}\n" "$l"
  printf "${C_CYAN}${BBl}%s${BBr}${R}\n" "$border"
}

# ─────────────────────────── project lookups ──────────────────────────────
proj_field() { local row="$1" idx="$2"; echo "$row" | cut -d'|' -f"$idx"; }
find_row() {
  local want="$1" row name
  for row in "${PROJECTS[@]}"; do
    name="$(proj_field "$row" 1)"; [ "$name" = "$want" ] && { echo "$row"; return 0; }
  done; return 1
}
frontend_port() { [ "$1" -ge 5001 ] 2>/dev/null || die "backend port '$1' too small for frontend_port (need >=5001)."; echo $(( $1 - 5000 )); }
is_repo_root() { [ -f "$1/hr-screening/docker-compose.yml" ]; }
# Container name currently bound to host port $1 ("" if none).
port_holder() { docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E ":${1}->" | awk '{print $1}' | head -1; }
# True (0) if something is listening on host port $1 that is NOT one of this
# project's containers -- catches a non-Docker process that would make
# `docker compose up` fail late after a multi-minute build (P1-3).
host_port_busy() {
  local port="$1"
  [ "$HAVE_CURL" = "1" ] || return 1            # can't probe without curl
  curl -s -o /dev/null -m 1 "http://localhost:$port/" 2>/dev/null || return 1   # nothing listening (refused/timeout)
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -qE ":${port}->" && return 1  # one of our containers
  return 0                                       # listening + not our container => host process
}
# State of a project: healthy | unhealthy | conflict | none
project_state() {
  local project="$1" backend="$2" code holder
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${project}-"; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://localhost:$backend/healthz" 2>/dev/null || echo 000)"
    [ "$code" = "200" ] && echo healthy || echo unhealthy; return 0
  fi
  holder="$(port_holder "$backend")"; [ -n "$holder" ] || holder="$(port_holder "$(frontend_port "$backend")")"
  [ -n "$holder" ] && echo conflict || echo none
}

# ───────────────────────────── locks + cleanup ────────────────────────────
BG_PID=""; LOCKDIR=""; LOCKDIRS=()
acq_lock() {
  local project="$1"; LOCKDIR="$LOCK_DIR/$project"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    # Stale-lock recovery: if the recorded holder PID is gone, reclaim it.
    if [ -f "$LOCKDIR/pid" ] && ! kill -0 "$(cat "$LOCKDIR/pid" 2>/dev/null)" 2>/dev/null; then
      warn "removing stale lock for '$project' (holder process no longer running)."
      rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" 2>/dev/null \
        || die "could not reclaim lock dir \"$LOCKDIR\"."
    else
      die "another quickstart is already managing '$project'.
If you are sure none is running, clear the stale lock:  rm -rf \"$LOCKDIR\""
    fi
  fi
  echo "$$" > "$LOCKDIR/pid"
  LOCKDIRS+=("$LOCKDIR")
}
cleanup() {
  [ -n "${BG_PID:-}" ] && kill "$BG_PID" 2>/dev/null
  wait "$BG_PID" 2>/dev/null
  local d
  for d in ${LOCKDIRS[@]+"${LOCKDIRS[@]}"}; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" 2>/dev/null
  done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap '' PIPE                      # don't die/noise when output is piped to `head`/`grep`
# EPIPE-tolerant writer for bulk loops (so `--list | head` exits clean).
emit() { printf "$@" 2>/dev/null || true; }

# ──────────────────────────── preflight: Docker ───────────────────────────
# Classify a Docker daemon failure so we print the RIGHT remedy. On a fresh
# Linux box the daemon is usually already up -- the failure is "permission
# denied" (this user isn't in the docker group), which the old single die()
# here mistook for a stopped daemon and "fixed" with a no-op
# `sudo systemctl start docker`. We capture docker's stderr to tell the cases
# apart -- the original `docker info >/dev/null 2>&1` discarded it, so every
# failure looked like "daemon not running".
check_docker_daemon() {
  docker info >/dev/null 2>&1 && return 0          # daemon reachable: done
  # Second call only on failure: capture stderr (the human reason) into $msg.
  # On the failure path docker prints nothing to stdout, so 2>&1 into the pipe
  # captures the reason and no >/dev/null is needed (which also sidesteps the
  # SC2069 `2>&1 >/dev/null` ordering trap). `local` and the assignment sit on
  # separate statements to satisfy ShellCheck SC2155.
  local msg; msg="$(docker info 2>&1 | tr -d '\r' | tail -n 6)"
  # Match case-insensitively: docker's exact capitalization varies by build and
  # locale, so compare against a lowercased copy ($msg_l) and keep the original
  # $msg only for display in the catch-all. A bare *"dial unix"* used to share
  # the permission arm -- but it also matched daemon-DOWN Go errors such as
  # "dial unix ... connect: connection refused", mis-sending users to
  # `usermod -aG docker`; "permission denied" alone covers every real
  # permission case, so the alternatives were dropped.
  local msg_l; msg_l="$(printf '%s' "$msg" | tr 'A-Z' 'a-z')"
  local dock; dock="$(command -v docker 2>/dev/null || true)"
  local docker_host_set=0 snap=0
  [ -n "${DOCKER_HOST:-}" ] && docker_host_set=1
  case "$dock" in /snap/*) snap=1 ;; esac
  case "$msg_l" in
    *"permission denied"*)
      cat >&2 <<EOF
${C_RED}${G_X} Docker is installed and the daemon is running -- but this user can't reach it.${R}

The Docker daemon socket on Linux is owned by ${C_BOLD}root:docker${R}. Add yourself to the
docker group (the standard fix), then re-run this script:

  ${C_BOLD}sudo usermod -aG docker \$USER${R}
  ${C_BOLD}newgrp docker${R}        ${C_DIM}(or log out and back in)${R}

Or, as a one-off, run the whole quickstart under sudo:

  ${C_BOLD}curl -fsSL https://raw.githubusercontent.com/hedypamungkas/koboi-projects/main/quickstart.sh | sudo bash${R}
EOF
      [ "$docker_host_set" = "1" ] && warn "DOCKER_HOST is set (${DOCKER_HOST:-}); if it points at a rootless daemon, start it with: systemctl --user start docker."
      [ "$snap" = "1" ] && warn "snap Docker detected ($dock); it uses stricter confinement -- if the group fix fails, try 'sudo snap start docker' or install Docker via apt instead."
      exit 1 ;;
    *"cannot connect to the docker daemon"*|*"is the docker daemon running"*|*"connection refused"*|*"no such file or directory"*)
      cat >&2 <<EOF
${C_RED}${G_X} Docker daemon is not reachable.${R}

Start it, then re-run:
  ${C_BOLD}Linux:${R}          sudo systemctl start docker ${C_DIM}&&${R} ${C_BOLD}sudo systemctl enable docker${R}
  ${C_BOLD}macOS / Windows:${R}  start Docker Desktop
EOF
      [ "$docker_host_set" = "1" ] && warn "DOCKER_HOST is set (${DOCKER_HOST:-}); if it points at a rootless daemon, start it with: systemctl --user start docker."
      exit 1 ;;
    *)
      local reason="$msg"
      [ -n "$reason" ] || reason="(docker printed no diagnostic; run: docker info)"
      die "Could not reach the Docker daemon (unexpected error):
$(printf '%s\n' "$reason" | sed 's/^/    /')" ;;
  esac
}

preflight() {
  step "Checking prerequisites"
  if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<EOF
${C_RED}${G_X} Docker is not installed or not on PATH.${R}

Install Docker, then re-run:
  ${C_BOLD}macOS / Windows:${R}  Docker Desktop  ${G_ARR} https://docs.docker.com/desktop/
  ${C_BOLD}Linux:${R}            Docker Engine + compose plugin ${G_ARR} https://docs.docker.com/engine/install/
(Windows: Docker Desktop installs WSL2; run this from a WSL2 or Git Bash shell.)
EOF
    exit 1
  fi
  docker compose version >/dev/null 2>&1 || die "Docker is installed but the 'docker compose' v2 plugin is missing (https://docs.docker.com/compose/install/)."
  check_docker_daemon
  if command -v curl >/dev/null 2>&1; then HAVE_CURL=1; else
    HAVE_CURL=0; warn "curl not found -- health checks will be skipped and the tarball clone fallback is unavailable (git clone still works)."
  fi
  if ! command -v git >/dev/null 2>&1; then warn "git not found -- will use a tarball download if the repo needs cloning."; fi
  ok "Docker ready (compose $(docker compose version --short 2>/dev/null || echo v2))."
}

# ─────────────────────────── bootstrap: repo ──────────────────────────────
tarball_url() { echo "${REPO_URL%.git}/archive/refs/heads/main.tar.gz"; }
# clone_repo <dest> -- git first, tarball fallback (works without git / behind simple firewalls).
clone_repo() {
  local dest="$1" tmp inner
  if command -v git >/dev/null 2>&1 && git clone --depth 1 "$REPO_URL" "$dest" >/dev/null 2>&1; then return 0; fi
  command -v curl >/dev/null 2>&1 || die "need git or curl to fetch the repo (neither found)."
  warn "git clone unavailable; downloading tarball..."
  tmp="$(mktemp -d)" || die "mktemp failed."
  curl -fsSL "$(tarball_url)" -o "$tmp/repo.tgz" || { rm -rf "$tmp"; die "download failed ($(tarball_url)). Is the repo published? Set KOBOI_UC_REPO to your fork."; }
  tar -xzf "$tmp/repo.tgz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; die "tarball extract failed."; }
  inner=""
  for _d in "$tmp"/*; do
    [ "$(basename "$_d")" = "repo.tgz" ] && continue   # SC2010: glob, not ls|grep
    inner="$(basename "$_d")"; break
  done
  unset _d
  [ -n "$inner" ] || { rm -rf "$tmp"; die "unexpected tarball layout."; }
  mv "$tmp/$inner" "$dest" 2>/dev/null || { rm -rf "$tmp"; die "cannot move repo into $dest."; }
  rm -rf "$tmp"; return 0
}
bootstrap_repo() {
  step "Locating the koboi-projects repo"
  if is_repo_root "$PWD"; then REPO_ROOT="$PWD"; ok "Running from a checkout: $REPO_ROOT"; return 0; fi
  if is_repo_root "$REPO_HOME"; then
    REPO_ROOT="$REPO_HOME"
    if has_tty && [ "$(prompt "Update existing checkout at $REPO_ROOT with git pull?" "Y/n")" != "n" ]; then
      local pout; pout="$(git -C "$REPO_ROOT" pull --ff-only 2>&1)" && ok "Updated." || warn "pull failed -- continuing with existing files. Reason: $(printf '%s' "$pout" | tail -1)"
    fi; return 0
  fi
  if has_tty && [ "$(prompt "Clone koboi-projects to $REPO_HOME?" "Y/n")" = "n" ]; then die "No repo available."; fi
  clone_repo "$REPO_HOME" || die "could not obtain the repo."
  REPO_ROOT="$REPO_HOME"; ok "Ready at $REPO_ROOT"
}
resolve_repo_root() {
  if is_repo_root "$PWD"; then REPO_ROOT="$PWD"
  elif is_repo_root "$REPO_HOME"; then REPO_ROOT="$REPO_HOME"
  else die "not inside a checkout and no clone at $REPO_HOME -- run 'quickstart.sh' (wizard) first."; fi
}

# ───────────────────────────── write .env ─────────────────────────────────
write_env() {
  local project="$1"
  local envfile="$REPO_ROOT/$project/.env"
  local ex="$REPO_ROOT/$project/.env.example"
  step "Configuring $project/.env"
  [ -f "$ex" ] || die "No .env.example for $project (expected $ex)."
  if [ -f "$envfile" ]; then
    local reuse="Y"
    has_tty && reuse="$(prompt "$project/.env already exists. Reuse it as-is?" "Y/n")"
    [ "$reuse" = "n" ] || { ok "Reusing existing $project/.env."; return 0; }
  fi
  local out="" key val def OPENAI_KEY_V="" OPENAI_BASE_V="" line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) out="$out$line"$'\n'; continue;; esac
    # A line without '=' would otherwise be written back as KEY=KEY (P1-5).
    if [[ "$line" != *=* ]]; then warn "ignoring line without '=' in .env.example: $line"; continue; fi
    key="${line%%=*}"; val="${line#*=}"
    if [ -n "$val" ]; then
      out="$out$key=$val"$'\n'
      case "$key" in OPENAI_API_KEY) OPENAI_KEY_V="$val";; OPENAI_BASE_URL) OPENAI_BASE_V="$val";; esac
      continue
    fi
    case "$key" in
      OPENAI_API_KEY)
        [ -n "${OPENAI_API_KEY:-}" ] && def="${OPENAI_API_KEY}" || def=""
        val="$(prompt_secret "OPENAI_API_KEY (required for live LLM)")"; [ -n "$val" ] || val="$def"
        [ -n "$val" ] || warn "empty OPENAI_API_KEY -- app boots but live chat will fail."
        OPENAI_KEY_V="$val" ;;
      OPENAI_MODEL)     val="$(prompt "OPENAI_MODEL" "${OPENAI_MODEL:-gpt-4o-mini}")" ;;
      OPENAI_BASE_URL)  val="$(prompt "OPENAI_BASE_URL (blank = public OpenAI)" "${OPENAI_BASE_URL:-}")"; OPENAI_BASE_V="$val" ;;
      EMBEDDING_API_KEY)  val="$(prompt "EMBEDDING_API_KEY" "${OPENAI_KEY_V}")" ;;
      EMBEDDING_BASE_URL) val="$(prompt "EMBEDDING_BASE_URL (blank = same as chat)" "${OPENAI_BASE_V:-}")" ;;
      *)                val="$(prompt "$key (blank = the app's built-in default)" "")" ;;
    esac
    out="$out$key=$val"$'\n'
  done < "$ex"
  printf '%s' "$out" > "$envfile" || die "cannot write $envfile (read-only checkout? run from your own clone)."
  chmod 600 "$envfile" 2>/dev/null || true
  # chmod is a no-op on some filesystems (FAT/exFAT, some CIFS mounts); read the
  # mode back and warn loudly if the secrets file isn't actually 600 (P1-6).
  local mode; mode="$(stat -f '%Lp' "$envfile" 2>/dev/null || stat -c '%a' "$envfile" 2>/dev/null || true)"
  if [ -n "$mode" ] && [ "$mode" != "600" ]; then
    warn "$project/.env is mode $mode (not 600) -- this filesystem may not honor chmod; OPENAI_API_KEY could be world-readable. Move the checkout off this filesystem."
  fi
  ok "Wrote $project/.env"
}

# ──────────────────────────── build + start ───────────────────────────────
compose() { docker compose --progress plain -f "$REPO_ROOT/$PROJECT_DIR/docker-compose.yml" "$@"; }

up_project() {
  local project="$1"
  local backend="$2"
  local log="$LOG_DIR/$project.log"
  acq_lock "$project"
  # fast-fail port conflicts (another container holding this project's ports)
  local h1 h2
  h1="$(port_holder "$backend")"; h2="$(port_holder "$(frontend_port "$backend")")"
  for h in "$h1" "$h2"; do
    [ -z "$h" ] && continue
    echo "$h" | grep -q "^${project}-" && continue
    die "port for $project is already in use by container '$h' (not $project).
Stop it ('docker rm -f $h' or 'quickstart.sh --down <other-project>') or pick another project."
  done
  # Host-process port occupancy (a non-Docker process docker can't see).
  if host_port_busy "$backend" || host_port_busy "$(frontend_port "$backend")"; then
    die "a host process is already listening on $project's port ($backend/$(frontend_port "$backend")) -- docker can't bind it. Stop that process or pick another project."
  fi
  step "Building + starting $project (first run pulls koboi-agent; ~1-3 min)"
  printf "  ${C_DIM}logs: %s${R}\n" "$log"
  : > "$log"
  ( compose up -d --build >"$log" 2>&1 ) &
  BG_PID=$!
  spinner "$BG_PID" "docker compose up --build" "$log"
  wait "$BG_PID"; local rc=$?; BG_PID=""
  if [ "$rc" -ne 0 ]; then
    tail -n 30 "$log" >&2
    printf "\n  ${C_DIM}full log: %s${R}\n  ${C_DIM}retry build clean: docker compose -f %s/%s/docker-compose.yml build --no-cache${R}\n" "$log" "$REPO_ROOT" "$project" >&2
    die "docker compose up failed (exit $rc)."
  fi
  ok "Containers started."
}

wait_health() {  # returns 0 healthy, 1 timed out
  local backend="$1" i code
  step "Waiting for koboi to be healthy on :$backend"
  if [ "$HAVE_CURL" = "0" ]; then
    HEALTH_UNVERIFIED=1
    warn "curl missing -- CANNOT verify /healthz. Waiting 15s and HOPING the container started; the URL below may fail. If it does, run 'quickstart.sh --logs <project>'."
    sleep 15; return 0
  fi
  for i in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://localhost:$backend/healthz" 2>/dev/null || echo 000)"
    if [ "$code" = "200" ]; then [ -t 1 ] && printf "\r\033[K"; ok "Healthy (:$backend/healthz ${G_ARR} 200)."; return 0; fi
    [ -t 1 ] && printf "\r  ${C_DIM}waiting... (%2ds, http=%s)${R}" "$((i*2))" "$code"
    sleep 2
  done
  [ -t 1 ] && printf "\r\033[K"; return 1
}

handle_unhealthy() {
  local project="$1" backend="$2"
  local log="$LOG_DIR/$project.log"   # separate statement: $project isn't visible mid-local
  echo; warn "$project did not become healthy on :$backend within ~180s."
  if has_tty; then
    while true; do
      printf "${C_BOLD}Now?${R} ${C_DIM}[w]ait more  [l]ogs  [s]top  [enter]=leave running${R} "
      local c=""; IFS= read -r c </dev/tty 2>/dev/null || c=""
      case "$c" in
        w) wait_health "$backend" && { print_summary "$project" "$backend"; return 0; } ;;
        l) compose logs --tail=40 ;;
        s) compose down; ok "stopped $project"; return 0 ;;
        ""|q) print_summary "$project" "$backend"; warn "containers left running (may still be starting)."; return 0 ;;
      esac
    done
  fi
  printf "  ${C_DIM}logs: %s -- containers left running; inspect with 'quickstart.sh --logs %s'.${R}\n" "$log" "$project" >&2
  exit 1
}

print_summary() {
  local project="$1" backend="$2"
  local front; front="$(frontend_port "$backend")"
  local key=""
  if [ -f "$REPO_ROOT/$project/.env" ]; then
    local _line; _line="$(grep -E '^CONCIERGE_API_KEY=' "$REPO_ROOT/$project/.env" 2>/dev/null | head -1 || true)"
    key="${_line#CONCIERGE_API_KEY=}"   # parameter expansion (cut -f2 mangles keys containing '=')
  fi
  echo; box "$project is up"
  [ "$HEALTH_UNVERIFIED" = "1" ] && warn "health was NOT verified (curl missing) -- the URL below is best-effort and may not respond yet."
  cat <<EOF
  ${C_BOLD}Web UI${R}   http://localhost:$front       ${C_DIM}(open this in your browser)${R}
  ${C_BOLD}API${R}      http://localhost:$backend     ${C_DIM}(/healthz, /v1/chat/stream, /v1/jobs)${R}
$([ -n "$key" ] && echo "  ${C_BOLD}API key${R}  $(mask "$key")  ${C_DIM}(Bearer token for this project)${R}")
  ${C_BOLD}Logs${R}     quickstart.sh --logs $project
  ${C_BOLD}Stop${R}     quickstart.sh --down $project
EOF
}

# ─────────────────────────── monitor loop ─────────────────────────────────
monitor_menu() {
  local project="$1" backend="$2" front; front="$(frontend_port "$backend")"
  has_tty || return 0
  while true; do
    echo
    printf "${C_BOLD}What next?${R} ${C_DIM}[t]ail logs  [c]url smoke  [o]pen browser  [n]ew project  [s]top  [q]uit${R} "
    local c=""; IFS= read -r c </dev/tty 2>/dev/null || c="q"
    case "$c" in
      t) compose logs -f --tail=30 || true ;;
      c) printf "\n${C_DIM}smoke:${R}\n  curl -s http://localhost:$backend/healthz\n"
         curl -s -m 5 "http://localhost:$backend/healthz" || echo "(no response)"
         printf "\n  ${C_DIM}(open http://localhost:$front to chat)${R}\n" ;;
      o|b) ( command -v open >/dev/null && open "http://localhost:$front" ) \
           || ( command -v xdg-open >/dev/null && xdg-open "http://localhost:$front" ) \
           || warn "no opener -- visit http://localhost:$front manually." ;;
      n) main_wizard; return ;;
      s|d) compose down >/dev/null 2>&1; ok "stopped $project"; return ;;
      q|x|"") return ;;
      *) warn "t/c/o/n/s/q" ;;
    esac
  done
}

# ──────────────────────────── interactive run ─────────────────────────────
pick_project() {
  local idx=0 row name title sub back mark choice="" read_failed=0
  # Menu -> STDERR. This fn used to be called as `run_project "$(pick_project)"`,
  # which captured the menu (stdout) and handed it back as a bogus "project name"
  # inside an error. Only the chosen name may reach stdout; the menu is UI, not data.
  echo >&2; printf "${C_BOLD}Choose a use case to run:${R}  ${C_DIM}(web/api ports shown)${R}\n" >&2
  for row in "${PROJECTS[@]}"; do
    idx=$((idx+1))
    name="$(proj_field "$row" 1)"; title="$(proj_field "$row" 2)"; sub="$(proj_field "$row" 3)"; back="$(proj_field "$row" 4)"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}-"; then mark="${C_GREEN}${G_BUL}running${R}"; else mark="${C_DIM}${G_DOT}${R}"; fi
    printf "  ${C_BOLD}%-2d${R} %-24s %-12s ${C_DIM}:%s/%s${R}\n" "$idx" "$name" "$mark" "$(frontend_port "$back")" "$back" >&2
    printf "     ${C_DIM}%s -- %s${R}\n" "$title" "$sub" >&2
  done
  if has_tty; then
    printf "%s " "${C_CYAN}?${R} ${C_BOLD}Number [1-${#PROJECTS[@]}]${R}" >&2
    # Read directly (not via the prompt() helper): we need the read's exit code to
    # tell EOF (can't interact at all) apart from an empty Enter, and we must stay
    # in THIS shell so a failure can exit the whole script (not a subshell).
    if ! IFS= read -r choice </dev/tty 2>/dev/null; then read_failed=1; fi
  else
    read_failed=1   # wizard mode reached with no usable terminal -> can't interact
  fi
  if [ "$read_failed" = "1" ]; then
    cat >&2 <<EOF
${C_RED}${G_X} Can't read keyboard input in this shell.${R}

This happens with ${C_BOLD}curl ... | bash${R} over some SSH / web-console sessions: the menu
shows, but the script never receives your keystrokes. Pick one:

  ${C_BOLD}1)${R} Run from the checkout (stdin is then your real terminal):
       cd "${KOBOI_UC_HOME:-$HOME/koboi-projects}" && bash quickstart.sh

  ${C_BOLD}2)${R} Or go non-interactive -- choose a project and set your key first:
       export OPENAI_API_KEY=sk-...
       bash quickstart.sh --project hr-screening --yes
     ${C_DIM}(see all projects: bash quickstart.sh --list)${R}

  ${C_BOLD}3)${R} If Docker also complained about permissions, add yourself once:
       sudo usermod -aG docker \$USER && newgrp docker
EOF
    exit 1
  fi
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#PROJECTS[@]}" ] \
    || die "invalid choice '$choice'."
  PICK_PROJECT="$(proj_field "${PROJECTS[$((choice-1))]}" 1)"
}

run_project() {
  local project="$1" row backend st
  row="$(find_row "$project")" || die "unknown project '$project' (--list shows names)."
  backend="$(proj_field "$row" 4)"; PROJECT_DIR="$project"
  st="$(project_state "$project" "$backend")"
  case "$st" in
    healthy)
      ok "$project is already running and healthy."
      print_summary "$project" "$backend"
      if has_tty; then
        case "$(prompt "Options: [r]estart  [l]ogs  [enter]=keep  [s]top" "")" in
          r|R) compose down >/dev/null 2>&1; up_project "$project" "$backend"; wait_health "$backend" || { handle_unhealthy "$project" "$backend"; return; } ;;
          l|L) compose logs -f --tail=30 ;;
          s|S) compose down >/dev/null 2>&1; ok "stopped $project"; return ;;
        esac
      fi
      monitor_menu "$project" "$backend"; return ;;
    conflict)
      local h; h="$(port_holder "$backend")"; [ -n "$h" ] || h="$(port_holder "$(frontend_port "$backend")")"
      die "port for $project is held by '$h' (not $project). Stop it first or pick another project." ;;
    unhealthy) warn "$project containers exist but are not healthy; restarting..."; compose down >/dev/null 2>&1 ;;
  esac
  write_env "$project"
  up_project "$project" "$backend"
  if wait_health "$backend"; then print_summary "$project" "$backend"; monitor_menu "$project" "$backend"
  else handle_unhealthy "$project" "$backend"; fi
}

main_wizard() { set_total_steps 5; preflight; bootstrap_repo; pick_project; run_project "$PICK_PROJECT"; }

# ─────────────────────────── subcommands ──────────────────────────────────
cmd_list() {
  emit "${C_BOLD}%-24s %-30s %-6s %-6s${R}\n" "PROJECT" "TITLE" "WEB" "API"
  local row name title back
  for row in "${PROJECTS[@]}"; do
    name="$(proj_field "$row" 1)"; title="$(proj_field "$row" 2)"; back="$(proj_field "$row" 4)"
    emit "%-24s %-30s %-6s %-6s\n" "$name" "$title" ":$(frontend_port "$back")" ":$back"
  done
}
cmd_status() {
  emit "${C_BOLD}koboi-projects containers:${R}\n"
  local row name back code front any=0
  for row in "${PROJECTS[@]}"; do
    name="$(proj_field "$row" 1)"; back="$(proj_field "$row" 4)"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}-"; then
      front="$(frontend_port "$back")"
      code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://localhost:$back/healthz" 2>/dev/null || echo 000)"
      emit "  ${C_GREEN}${G_BUL}${R} %-22s web http://localhost:%-5s api http://localhost:%-5s healthz=%s\n" "$name" "$front" "$back" "$code"; any=1
    fi
  done
  [ "$any" = "0" ] && emit "  ${C_DIM}(none running)${R}\n"
}
cmd_logs() {
  resolve_repo_root; PROJECT_DIR="${1:-}"; [ -n "$PROJECT_DIR" ] || die "usage: --logs <project>"
  find_row "$PROJECT_DIR" >/dev/null || die "unknown project '$PROJECT_DIR'."
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${PROJECT_DIR}-" || { warn "$PROJECT_DIR is not running."; return; }
  compose logs -f --tail=50
}
cmd_down() {
  resolve_repo_root; PROJECT_DIR="${1:-}"; [ -n "$PROJECT_DIR" ] || die "usage: --down <project>"
  find_row "$PROJECT_DIR" >/dev/null || die "unknown project '$PROJECT_DIR'."
  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${PROJECT_DIR}-"; then warn "$PROJECT_DIR is not running (nothing to stop)."; return; fi
  local extra=""; [ "${2:-}" = "--purge" ] && extra="-v"
  docker compose --progress plain -f "$REPO_ROOT/$PROJECT_DIR/docker-compose.yml" down $extra >/dev/null 2>&1 \
    && ok "stopped $PROJECT_DIR$([ -n "$extra" ] && echo ' (+volumes)')" || warn "stop had issues; see 'docker ps'."
}
cmd_update() {
  resolve_repo_root
  local pout; pout="$(git -C "$REPO_ROOT" pull --ff-only 2>&1)" && ok "updated $REPO_ROOT" \
    || warn "git pull failed. Reason: $(printf '%s' "$pout" | tail -1)  (cloned via tarball?)"
}

usage() {
  cat <<EOF
${C_BOLD}koboi-projects quickstart${R} -- run any of the 10 apps in one command.

${C_BOLD}Usage:${R}
  quickstart.sh                       interactive wizard (default)
  quickstart.sh --project <name>      run one project (prompts for .env if missing)
  quickstart.sh --project <name> --yes  non-interactive (defaults / shell env)
  quickstart.sh --list                list all projects + ports
  quickstart.sh --status              running projects + health
  quickstart.sh --logs <name>         tail a project's logs
  quickstart.sh --down <name> [--purge]  stop (optionally drop volumes)
  quickstart.sh --update              git pull the repo

${C_BOLD}Env overrides:${R}  KOBOI_UC_REPO  KOBOI_UC_HOME  NO_COLOR=1  KOBOI_NO_UTF8=1
${C_BOLD}Pre-seed (CI):${R}  OPENAI_API_KEY=sk-... quickstart.sh --project hr-screening --yes
EOF
}

# ───────────────────────────── dispatch ───────────────────────────────────
PROJECT_FLAG=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || die "--project requires a project name (try --list)."
      PROJECT_FLAG="$2"; shift 2;;
    --yes|-y) YES=1; FORCE_NONINTERACTIVE=1; shift;;
    --no-color) export NO_COLOR=1; shift;;
    --no-utf8) export KOBOI_NO_UTF8=1; shift;;
    --list)   cmd_list; exit 0;;
    --status) cmd_status; exit 0;;
    --logs)   cmd_logs "${2:-}"; exit 0;;
    --down)   cmd_down "${2:-}" "${3:-}"; exit 0;;
    --update) cmd_update; exit 0;;
    --help|-h) usage; exit 0;;
    *) die "unknown arg '$1' (try --help)";;
  esac
done

# validate project name early (before any Docker work)
if [ -n "$PROJECT_FLAG" ]; then find_row "$PROJECT_FLAG" >/dev/null || die "unknown project '$PROJECT_FLAG' (--list shows names)."; fi
# --yes is only meaningful with --project; otherwise pick_project dies with an opaque "invalid choice ''".
[ "$YES" = "1" ] && [ -z "$PROJECT_FLAG" ] && die "--yes requires --project <name> (try --list)."

banner() {
  # Guard the whole banner with is_utf8 (the rest of the script uses guarded
  # glyph vars, but this previously hardcoded Unicode -> mojibake on non-UTF8).
  if is_utf8; then
    printf "\n${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════╗${R}\n"
    printf "${C_BOLD}${C_CYAN}║   koboi-projects quickstart - pick, configure, run    ║${R}\n"
    printf "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════╝${R}\n\n"
  else
    printf "\n${C_BOLD}${C_CYAN}========================================================${R}\n"
    printf "${C_BOLD}${C_CYAN}   koboi-projects quickstart - pick, configure, run     ${R}\n"
    printf "${C_BOLD}${C_CYAN}========================================================${R}\n\n"
  fi
}
banner
if [ -n "$PROJECT_FLAG" ]; then
  set_total_steps 5; preflight; bootstrap_repo; run_project "$PROJECT_FLAG"
else
  main_wizard
fi
echo; ok "Done."
