#!/usr/bin/env bash
# Arkiova Studio worker setup for Linux (Debian/Ubuntu) and macOS.
#
# Turns this computer into an Arkiova Studio worker in the same seven steps as setup.ps1:
#   1. read the hardware (cores, memory, free disk, NVIDIA GPU and VRAM)
#   2. propose the worker settings and let you confirm or change each one
#   3. install only the missing tools (apt on Debian/Ubuntu, brew on macOS)
#   4. check the three logins (GitHub, the AWS profile arkiova-studio, Claude Code)
#   5. clone or update arkiova/studio and arkiova/motion-agent, install their dependencies,
#      the engine's TTS Python env and the voice models
#   6. write <workDir>/studio.worker.json, run `studio doctor` and `studio worker --once --dry`
#   7. autostart: a systemd --user unit (Linux) or a launchd agent (macOS)
# Re-running it updates the clones and dependencies and changes nothing else.
# It never prints, logs or copies a key or token.
#
#   curl -fsSL https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/arkiova/studio-starter/main/setup.sh | bash -s -- --yes
#
# Runs on macOS's bash 3.2, so no bash 4 features (no ${x,,}, mapfile or associative arrays).
set -euo pipefail

DRY_RUN=0
YES=0
WORK_DIR=""
NAME=""
ENGINE_PATH=""
NO_AUTOSTART=0
UNINSTALL=0

readonly SERVICE_NAME="arkiova-studio-worker"
readonly LAUNCHD_LABEL="com.arkiova.studio-worker"
readonly STUDIO_REPO="arkiova/studio"
readonly ENGINE_REPO="arkiova/motion-agent"
readonly DEFAULT_REPOS="-" # every repo tagged arkiova-studio, which the workers discover (new courses included)
readonly AWS_PROFILE_NAME="arkiova-studio"
readonly AWS_IAM_USER="arkiova-studio-worker"
readonly SSM_PARAMETER="/arkiova-studio/config"
readonly GH_SCOPES="repo,project,read:org"
readonly MIN_CLAUDE="2.1.41"
readonly CONFIG_NAME="studio.worker.json"
readonly RUNNER_NAME="run-worker.sh"
readonly STAMP_NAME=".studio-starter"
readonly RAW_BASE="https://raw.githubusercontent.com/arkiova/studio-starter/main"

PLATFORM=""
PLAN=""
SETTING=""
REPLY_TEXT=""
APT_UPDATED=0
WORKER_STOPPED=0
API_URL=""
HAS_GPU=0
DISCOVERY_WHY=""
ENGINE_MANAGED=1
CFG_WORK_DIR="" CFG_NAME="" CFG_CAPS="" CFG_DEVICE="" CFG_JOBS="" CFG_CACHE="" CFG_ACCOUNT="" CFG_REPOS="" CFG_ENGINE="" CFG_POLL=45

if [ -t 1 ]; then
  C_STEP=$'\033[36m' C_OK=$'\033[32m' C_DRY=$'\033[35m' C_WARN=$'\033[33m' C_ERR=$'\033[31m' C_OFF=$'\033[0m'
else
  C_STEP='' C_OK='' C_DRY='' C_WARN='' C_ERR='' C_OFF=''
fi

# ------------------------------------------------------------------ output

step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_OFF"; }
info() { printf '    %s\n' "$1"; }
tagged() { printf '    %s%-6s%s%s\n' "$2" "$1" "$C_OFF" "$3"; }
ok() { tagged ok "$C_OK" "$1"; }
dry() { tagged dry "$C_DRY" "$1"; }
running() { tagged run "$C_STEP" "$1"; }
warn() { tagged warn "$C_WARN" "$1"; }
todo() { tagged todo "$C_WARN" "$1"; }

# Stops setup: $1 says what failed, $2 says what to do about it.
fail() {
  printf '\n%sFAILED  %s%s\n' "$C_ERR" "$1" "$C_OFF" >&2
  printf '%sNext:   %s%s\n' "$C_WARN" "${2:-fix the error above, then re-run setup.}" "$C_OFF" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Arkiova Studio worker setup (Linux and macOS)

  --dry-run            show what would happen; install, clone, write and register nothing
  --yes, -y            accept every proposal without asking (the logins still need you)
  --work-dir <dir>     the work folder (default: <disk with the most free space>/agentic-video-generation/_worker)
  --name <name>        the worker name (default: the hostname, lowercased)
  --engine-path <dir>  reuse an existing motion-agent checkout (setup installs its dependencies, never pulls it)
  --no-autostart       don't set up the systemd --user unit or launchd agent
  --uninstall          remove the autostart and, after you confirm, the work folder (tools and logins stay)
EOF
}

# ------------------------------------------------------------------ small helpers

have() { command -v "$1" >/dev/null 2>&1; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

has_tty() { (exec 3</dev/tty) 2>/dev/null; }

# Asks on the terminal (stdin may be the script itself under curl | bash); sets REPLY_TEXT.
ask_tty() {
  REPLY_TEXT=""
  if ! has_tty; then
    fail "This step needs an answer, but there is no terminal to ask in." "Run setup from a terminal, or pass --yes to accept the proposals."
  fi
  printf '%s' "$1" >/dev/tty
  IFS= read -r REPLY_TEXT </dev/tty || REPLY_TEXT=""
}

ask_yes_no() {
  local hint='[y/N]'
  if [ "$YES" = 1 ]; then return 0; fi
  if [ "$2" = y ]; then hint='[Y/n]'; fi
  while true; do
    ask_tty "    $1 $hint "
    case $REPLY_TEXT in
      '') if [ "$2" = y ]; then return 0; else return 1; fi ;;
      y | Y | yes | Yes | YES) return 0 ;;
      n | N | no | No | NO) return 1 ;;
    esac
    warn "Please answer y or n."
  done
}

# Runs the check named $1 on $2; it prints a problem, or nothing when the value is fine.
run_check() {
  case $1 in
    work_dir) check_work_dir "$2" ;;
    name) check_name "$2" ;;
    caps) check_caps "$2" ;;
    device) check_device "$2" ;;
    count) check_count "$2" ;;
    account) check_account "$2" ;;
    repos) check_repos "$2" ;;
  esac
}

# Asks for one setting, showing the proposal; Enter keeps it. $3 names the check (see run_check).
read_setting() {
  local label=$1 default=$2 check=$3 problem
  if [ "$YES" = 1 ]; then
    problem=$(run_check "$check" "$default")
    if [ -n "$problem" ]; then
      fail "The proposed $label '$default' can't be used: $problem" "Pass a valid value as an option, or run without --yes and type one."
    fi
    info "$(printf '%-14s %s' "$label" "$default")"
    SETTING=$default
    return 0
  fi
  while true; do
    ask_tty "$(printf '    %-14s [%s]: ' "$label" "$default")"
    if [ -z "$REPLY_TEXT" ]; then REPLY_TEXT=$default; fi
    problem=$(run_check "$check" "$REPLY_TEXT")
    if [ -z "$problem" ]; then
      SETTING=$REPLY_TEXT
      return 0
    fi
    warn "$problem"
  done
}

# One list item per line: anything but letters, digits and . _ / - separates items.
split_lines() { printf '%s\n' "$1" | tr -c '[:alnum:]._/-' '\n' | sed '/^$/d'; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# First x.y[.z] in a command's output, or nothing.
version_of() { "$@" 2>/dev/null </dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true; }

# 0 when version $1 >= version $2.
version_ge() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  a1=${a1:-0} a2=${a2:-0} a3=${a3:-0} b1=${b1:-0} b2=${b2:-0} b3=${b3:-0}
  a1=${a1%%[!0-9]*} a2=${a2%%[!0-9]*} a3=${a3%%[!0-9]*}
  b1=${b1%%[!0-9]*} b2=${b2%%[!0-9]*} b3=${b3%%[!0-9]*}
  if [ "${a1:-0}" -ne "${b1:-0}" ]; then [ "${a1:-0}" -gt "${b1:-0}" ]; return; fi
  if [ "${a2:-0}" -ne "${b2:-0}" ]; then [ "${a2:-0}" -gt "${b2:-0}" ]; return; fi
  [ "${a3:-0}" -ge "${b3:-0}" ]
}

file_hash() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

json_list() {
  local out="" item
  while IFS= read -r item; do
    if [ -n "$item" ]; then out="${out:+$out, }$(json_str "$item")"; fi
  done <<<"$(split_lines "$1")"
  printf '[%s]' "$out"
}

# Replacements are quoted: bash 5.2 reads a bare & in one as "the matched text".
xml_escape() {
  local s=$1
  s=${s//&/"&amp;"}
  s=${s//</"&lt;"}
  s=${s//>/"&gt;"}
  printf '%s' "$s"
}

# Reads one key of a worker config (arrays come back comma-joined).
cfg_get() {
  local file=$1 key=$2
  if [ ! -f "$file" ]; then return 0; fi
  if have node; then
    node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=c[process.argv[2]];if(v!==undefined&&v!==null)process.stdout.write(Array.isArray(v)?v.join(","):String(v))' "$file" "$key" 2>/dev/null || true
  else
    sed -n "s/^[[:space:]]*\"$key\":[[:space:]]*//p" "$file" | head -n 1 |
      sed 's/,[[:space:]]*$//; s/^\[//; s/\]$//; s/"//g; s/,[[:space:]]*/,/g'
  fi
}

# Puts tools installed a moment ago on PATH for the rest of this run.
refresh_path() {
  local brew_bin keg
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    if [ -x "$brew_bin" ]; then
      eval "$("$brew_bin" shellenv)"
      break
    fi
  done
  if have brew; then
    keg="$(brew --prefix)/opt/node@24/bin"
    if [ -d "$keg" ]; then PATH="$keg:$PATH"; fi
  fi
  if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
  fi
  export PATH
  hash -r
}

# ------------------------------------------------------------------ 1. hardware

cpu_cores() {
  if [ "$PLATFORM" = mac ]; then sysctl -n hw.logicalcpu; else getconf _NPROCESSORS_ONLN 2>/dev/null || nproc; fi
}

ram_gb() {
  if [ "$PLATFORM" = mac ]; then
    awk -v b="$(sysctl -n hw.memsize)" 'BEGIN { printf "%.1f", b / 1073741824 }'
  else
    awk '/^MemTotal:/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo
  fi
}

# Real disks, one per line: mount<TAB>free KB<TAB>size KB. On Linux anything but pseudo
# filesystems counts (so ZFS datasets and LVM volumes do); on macOS only /dev devices.
list_disks() {
  df -Pk 2>/dev/null | awk -v platform="$PLATFORM" '
    NR > 1 {
      m = $6; for (i = 7; i <= NF; i++) m = m " " $i
      if (platform == "mac" && $1 !~ /^\/dev\//) next
      if ($1 ~ /^(tmpfs|devtmpfs|udev|overlay|shm|none|efivarfs|cgroup2?|proc|sysfs|ramfs|portal|gvfsd-fuse)$/) next
      if ($1 ~ /^\/dev\/loop/ || $2 == 0) next
      if (m ~ /^\/(boot|boot\/efi|run|sys|proc|dev)(\/|$)/ || m ~ /^\/snap\// || m ~ /^\/private\/var\/vm$/) next
      if (m ~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware)$/) next
      print m "\t" $4 "\t" $2
    }' || true
}

home_mount() {
  df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { m = $6; for (i = 7; i <= NF; i++) m = m " " $i; print m }' || true
}

gpu_lines() {
  if have nvidia-smi; then
    nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits 2>/dev/null || true
  fi
}

show_hardware() {
  local mount free size gname gtotal gfree gpus
  step "1/7 Hardware"
  info "$(printf '%-10s %s logical' cores "$(cpu_cores)")"
  info "$(printf '%-10s %s GB' memory "$(ram_gb)")"
  while IFS=$'\t' read -r mount free size; do
    if [ -n "$mount" ]; then
      info "$(printf '%-10s %s GB free of %s GB' disk "$(awk -v k="$free" 'BEGIN { printf "%.1f", k / 1048576 }')" "$(awk -v k="$size" 'BEGIN { printf "%.1f", k / 1048576 }')")  ($mount)"
    fi
  done <<<"$(list_disks)"
  gpus=$(gpu_lines)
  if [ -z "$gpus" ]; then
    info "$(printf '%-10s %s' gpu 'no NVIDIA GPU found (TTS will use the CPU)')"
    HAS_GPU=0
  else
    HAS_GPU=1
    while IFS=, read -r gname gtotal gfree; do
      if [ -n "$gname" ]; then
        info "$(printf '%-10s %s, %s GB VRAM, %s GB free' gpu "$gname" \
          "$(awk -v m="${gtotal// /}" 'BEGIN { printf "%.1f", m / 1024 }')" \
          "$(awk -v m="${gfree// /}" 'BEGIN { printf "%.1f", m / 1024 }')")"
      fi
    done <<<"$gpus"
  fi
}

# ------------------------------------------------------------------ 2. settings

unit_file() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$SERVICE_NAME.service"; }
plist_file() { printf '%s' "$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"; }

# The work folder an earlier run set up: from the autostart, else the default place.
existing_work_dir() {
  local f d=""
  if [ "$PLATFORM" = linux ]; then
    f=$(unit_file)
    if [ -f "$f" ]; then d=$(sed -n 's/^WorkingDirectory=//p' "$f" | head -n 1); fi
  else
    f=$(plist_file)
    if [ -f "$f" ]; then
      # The value is on the key's line (as setup writes it) or on the next one.
      d=$(awk '/<key>WorkingDirectory<\/key>/ {
        sub(/^.*<key>WorkingDirectory<\/key>/, ""); if ($0 !~ /<string>/) getline
        sub(/^.*<string>/, ""); sub(/<\/string>.*$/, ""); print; exit }' "$f")
      d=${d//"&lt;"/"<"}
      d=${d//"&gt;"/">"}
      d=${d//"&amp;"/"&"}
    fi
  fi
  if [ -n "$d" ]; then
    printf '%s' "$d"
  elif [ -f "$HOME/agentic-video-generation/_worker/$CONFIG_NAME" ]; then
    printf '%s' "$HOME/agentic-video-generation/_worker"
  fi
}

propose_work_dir() {
  local existing hm best="" best_free=-1 mount free cand
  if [ -n "$WORK_DIR" ]; then printf '%s' "$WORK_DIR"; return 0; fi
  existing=$(existing_work_dir)
  if [ -n "$existing" ]; then printf '%s' "$existing"; return 0; fi
  hm=$(home_mount)
  while IFS=$'\t' read -r mount free _; do
    if [ -z "$mount" ]; then continue; fi
    if [ "$mount" = "$hm" ]; then
      cand="$HOME/agentic-video-generation/_worker"
    elif [ -w "$mount" ]; then
      cand="${mount%/}/agentic-video-generation/_worker"
    else
      continue
    fi
    if [ "$free" -gt "$best_free" ]; then
      best_free=$free
      best=$cand
    fi
  done <<<"$(list_disks)"
  printf '%s' "${best:-$HOME/agentic-video-generation/_worker}"
}

proposed_name() {
  local n
  n=$(hostname -s 2>/dev/null || hostname)
  n=$(lower "$n" | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c 1-63)
  printf '%s' "${n:-worker}"
}

is_onedrive() {
  case "$(lower "$1")" in
    */onedrive | */onedrive/* | */onedrive-* | */onedrive\ -*) return 0 ;;
  esac
  return 1
}

check_work_dir() {
  local probe
  case $1 in
    /*) ;;
    *) echo "use a full path, such as $HOME/agentic-video-generation/_worker"; return 0 ;;
  esac
  if [ "$1" = / ]; then echo "pick a folder, not /"; return 0; fi
  if is_onedrive "$1"; then
    echo "OneDrive folders are refused: syncing gigabytes of scratch would fight the worker. Pick a folder outside OneDrive"
    return 0
  fi
  probe=$1
  while [ ! -e "$probe" ]; do probe=$(dirname "$probe"); done
  if [ ! -d "$probe" ] || [ ! -w "$probe" ]; then echo "you can't write to $probe; pick a folder you own"; fi
}

check_name() {
  if ! [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then echo "use lowercase letters, digits and hyphens (at most 63)"; fi
}

check_caps() {
  local items
  case $1 in *[!-[:alnum:]._/,\ ]*) echo "use agent, render and tts, separated by commas"; return 0 ;; esac
  items=$(split_lines "$1")
  if [ -z "$items" ]; then echo "list at least one of agent, render, tts"; return 0; fi
  if printf '%s\n' "$items" | grep -Evq '^(agent|render|tts)$'; then echo "only agent, render and tts are allowed"; fi
}

normalize_caps() {
  local items out="" c
  items=$(split_lines "$1")
  for c in agent render tts; do
    if printf '%s\n' "$items" | grep -qx "$c"; then out="${out:+$out,}$c"; fi
  done
  printf '%s' "$out"
}

check_device() {
  case $1 in auto | cuda | cpu) ;; *) echo "use auto, cuda or cpu" ;; esac
}

check_count() {
  if ! [[ $1 =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ]; then echo "use a whole number, 1 or more"; fi
}

check_account() {
  if ! [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then echo "use letters, digits, dots, hyphens or underscores"; fi
}

check_repos() {
  local items
  case $1 in *[!-[:alnum:]._/,\ ]*) echo "use owner/repo, separated by commas"; return 0 ;; esac
  # "-" or nothing: every repo tagged arkiova-studio
  items=$(split_lines "$1" | sed '/^-$/d')
  if [ -z "$items" ]; then return 0; fi
  if printf '%s\n' "$items" | grep -Evq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then echo "use owner/repo, separated by commas, or - for every repo tagged arkiova-studio"; fi
}

is_engine_checkout() { [ -f "$1/package.json" ] && [ -f "$1/tts/requirements.txt" ]; }

read_settings() {
  local old v managed note
  step "2/7 Settings"
  if [ "$YES" != 1 ]; then info "Press Enter to keep the value in brackets, or type a new one."; fi

  # workDir comes first: the other proposals may come from a config already in it.
  read_setting workDir "$(propose_work_dir)" work_dir
  CFG_WORK_DIR=${SETTING%/}
  old="$CFG_WORK_DIR/$CONFIG_NAME"
  if [ -f "$old" ]; then info "(the other proposals come from the existing $CONFIG_NAME)"; fi

  v=$NAME
  if [ -z "$v" ]; then v=$(cfg_get "$old" name); fi
  if [ -z "$v" ]; then v=$(proposed_name); fi
  read_setting name "$v" name
  CFG_NAME=$SETTING

  v=$(cfg_get "$old" capabilities)
  read_setting capabilities "${v:-agent,render,tts}" caps
  CFG_CAPS=$(normalize_caps "$SETTING")

  v=$(cfg_get "$old" ttsDevice)
  read_setting ttsDevice "${v:-auto}" device
  CFG_DEVICE=$SETTING

  v=$(cfg_get "$old" maxJobs)
  read_setting maxJobs "${v:-$(cpu_cores)}" count
  CFG_JOBS=$SETTING

  v=$(cfg_get "$old" cacheBudgetGB)
  read_setting cacheBudgetGB "${v:-5}" count
  CFG_CACHE=$SETTING

  v=$(cfg_get "$old" claudeAccount)
  read_setting claudeAccount "${v:-main}" account
  CFG_ACCOUNT=$SETTING

  v=$(cfg_get "$old" repos)
  read_setting repos "${v:-$DEFAULT_REPOS}" repos
  CFG_REPOS=$(split_lines "$SETTING" | sed '/^-$/d' | paste -sd, -)

  v=$(cfg_get "$old" pollSeconds)
  CFG_POLL=${v:-45}

  # The engine: --engine-path, else the one the existing config names, else a clone in the work folder.
  managed="$CFG_WORK_DIR/motion-agent"
  CFG_ENGINE=$managed
  if [ -n "$ENGINE_PATH" ]; then
    CFG_ENGINE=${ENGINE_PATH%/}
    if ! is_engine_checkout "$CFG_ENGINE"; then
      fail "--engine-path $CFG_ENGINE is not a motion-agent checkout (no package.json or tts/requirements.txt)." \
        "Point --engine-path at a motion-agent clone, or leave it out to clone one into the work folder."
    fi
  else
    v=$(cfg_get "$old" enginePath)
    if [ -n "$v" ] && [ "$v" != "$managed" ]; then
      if is_engine_checkout "$v"; then CFG_ENGINE=$v; else warn "the configured engine $v is gone; using a clone in the work folder instead"; fi
    fi
  fi
  if [ "$CFG_ENGINE" = "$managed" ]; then
    ENGINE_MANAGED=1
    note="cloned and updated by setup"
  else
    ENGINE_MANAGED=0
    note="existing checkout: setup installs its dependencies but never pulls it"
  fi
  info "$(printf '%-14s %s (%s)' enginePath "$CFG_ENGINE" "$note")"
}

# ------------------------------------------------------------------ 3. tools

plan_add() { PLAN="${PLAN}$1|$2|$3"$'\n'; }

python311() {
  local p
  for p in python3.11 /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11; do
    if have "$p"; then command -v "$p"; return 0; fi
  done
  return 0
}

node_major() { node --version 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\).*/\1/p'; }

build_plan() {
  local base="" b py claude_version aws_version major
  PLAN=""
  if [ "$PLATFORM" = mac ] && ! have brew; then plan_add brew "Homebrew" "missing (it installs the rest)"; fi
  if [ "$PLATFORM" = linux ]; then
    for b in curl unzip gpg; do
      if ! have "$b"; then base="$base $b"; fi
    done
    if [ -n "$base" ]; then plan_add base "curl, unzip and gnupg" "missing:$base"; fi
  fi

  if have git; then ok "$(printf '%-12s %s' Git "$(version_of git --version)")"; else plan_add git "Git" "missing"; fi

  major=$(node_major)
  if [ -n "$major" ] && [ "$major" -ge 24 ]; then
    ok "$(printf '%-12s %s' Node.js "$(version_of node --version)")"
  elif [ -n "$major" ]; then
    plan_add node "Node.js 24" "found $(version_of node --version), the studio needs 24"
  else
    plan_add node "Node.js 24" "missing"
  fi

  py=$(python311)
  if [ -n "$py" ] && { [ "$PLATFORM" = mac ] || "$py" -c 'import ensurepip, venv' >/dev/null 2>&1; }; then
    ok "$(printf '%-12s %s' 'Python 3.11' "$py")"
  elif [ -n "$py" ]; then
    plan_add python "Python 3.11 venv support" "python3.11 has no venv module"
  else
    plan_add python "Python 3.11" "missing (the engine TTS needs 3.11 exactly)"
  fi

  if have ffmpeg && have ffprobe; then ok "$(printf '%-12s %s' ffmpeg "$(version_of ffmpeg -version)")"; else plan_add ffmpeg "ffmpeg + ffprobe" "missing"; fi
  if have gh; then ok "$(printf '%-12s %s' 'GitHub CLI' "$(version_of gh --version)")"; else plan_add gh "GitHub CLI" "missing"; fi

  aws_version=""
  if have aws; then aws_version=$(version_of aws --version); fi
  case $aws_version in
    2.*) ok "$(printf '%-12s %s' 'AWS CLI' "$aws_version")" ;;
    '') plan_add aws "AWS CLI v2" "missing" ;;
    *) plan_add aws "AWS CLI v2" "found $aws_version, need v2" ;;
  esac

  claude_version=""
  if have claude; then claude_version=$(version_of claude --version); fi
  if [ -n "$claude_version" ] && version_ge "$claude_version" "$MIN_CLAUDE"; then
    ok "$(printf '%-12s %s' 'Claude Code' "$claude_version")"
  elif [ -n "$claude_version" ]; then
    plan_add claude "Claude Code" "found $claude_version, need $MIN_CLAUDE or newer"
  else
    plan_add claude "Claude Code" "missing"
  fi
}

plan_line() {
  if [ "$PLATFORM" = mac ]; then
    case $1 in
      brew) echo "Homebrew: the official installer from brew.sh" ;;
      git) echo "Git: brew install git" ;;
      node) echo "Node.js 24: brew install node@24 (then brew link node@24)" ;;
      python) echo "Python 3.11: brew install python@3.11" ;;
      ffmpeg) echo "ffmpeg: brew install ffmpeg" ;;
      gh) echo "GitHub CLI: brew install gh" ;;
      aws) echo "AWS CLI v2: brew install awscli" ;;
      claude) echo "Claude Code: official installer (curl -fsSL https://claude.ai/install.sh | bash), npm if that fails" ;;
    esac
  else
    case $1 in
      base) echo "curl, unzip, gnupg: apt-get install curl ca-certificates unzip gnupg" ;;
      git) echo "Git: apt-get install git" ;;
      node) echo "Node.js 24: NodeSource repository (deb.nodesource.com/setup_24.x), apt-get install nodejs" ;;
      python) echo "Python 3.11: apt-get install python3.11 python3.11-venv (deadsnakes PPA on Ubuntu if needed)" ;;
      ffmpeg) echo "ffmpeg: apt-get install ffmpeg" ;;
      gh) echo "GitHub CLI: GitHub's apt repository (cli.github.com/packages), apt-get install gh" ;;
      aws) echo "AWS CLI v2: the official installer from awscli.amazonaws.com" ;;
      claude) echo "Claude Code: official installer (curl -fsSL https://claude.ai/install.sh | bash), npm if that fails" ;;
    esac
  fi
}

apt_update() {
  if [ "$APT_UPDATED" = 1 ]; then return 0; fi
  as_root apt-get update </dev/null || fail "apt-get update failed." "Fix the apt sources it complains about, then re-run setup."
  APT_UPDATED=1
}

apt_install() {
  apt_update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" </dev/null ||
    fail "apt-get could not install $*." "Run 'sudo apt-get install $*' yourself to see why, then re-run setup."
}

install_claude() {
  if curl -fsSL https://claude.ai/install.sh | bash; then
    refresh_path
    if have claude; then return 0; fi
  fi
  warn "the official Claude Code installer did not finish; trying npm"
  have npm || fail "Could not install Claude Code." "Install it yourself (curl -fsSL https://claude.ai/install.sh | bash), then re-run setup."
  npm install -g --prefix "$HOME/.local" @anthropic-ai/claude-code </dev/null ||
    fail "Could not install Claude Code with npm either." "Install it yourself (curl -fsSL https://claude.ai/install.sh | bash), then re-run setup."
  refresh_path
}

install_linux_tool() {
  local tmp arch candidate os_id=""
  case $1 in
    base) apt_install curl ca-certificates unzip gnupg ;;
    git) apt_install git ;;
    ffmpeg) apt_install ffmpeg ;;
    node)
      tmp=$(mktemp)
      curl -fsSL https://deb.nodesource.com/setup_24.x -o "$tmp" || fail "Could not download the NodeSource setup script." "Check the network, then re-run setup."
      as_root bash "$tmp" </dev/null || fail "The NodeSource setup script failed." "Read its error above, then re-run setup."
      rm -f "$tmp"
      APT_UPDATED=0
      apt_install nodejs
      ;;
    python)
      apt_update
      candidate=$(apt-cache policy python3.11 2>/dev/null | awk '/Candidate:/ { print $2 }' || true)
      if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
        if [ -r /etc/os-release ]; then os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"'); fi
        if [ "$os_id" != ubuntu ]; then
          fail "Python 3.11 is not available from apt here." "Install Python 3.11 yourself (for example with pyenv or uv) so python3.11 is on PATH, then re-run setup."
        fi
        apt_install software-properties-common
        as_root add-apt-repository -y ppa:deadsnakes/ppa </dev/null || fail "Could not add the deadsnakes PPA." "Add it yourself, then re-run setup."
        APT_UPDATED=0
      fi
      apt_install python3.11 python3.11-venv
      ;;
    gh)
      as_root mkdir -p -m 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | as_root tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null ||
        fail "Could not download GitHub's apt key." "Check the network, then re-run setup."
      as_root chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$(dpkg --print-architecture)" |
        as_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      APT_UPDATED=0
      apt_install gh
      ;;
    aws)
      tmp=$(mktemp -d)
      arch=$(uname -m)
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$arch.zip" -o "$tmp/awscliv2.zip" ||
        fail "Could not download the AWS CLI." "Check the network, then re-run setup."
      unzip -q -o "$tmp/awscliv2.zip" -d "$tmp" || fail "Could not unpack the AWS CLI." "Re-run setup."
      as_root "$tmp/aws/install" --update </dev/null || fail "The AWS CLI installer failed." "Read its error above, then re-run setup."
      rm -rf "$tmp"
      ;;
    claude) install_claude ;;
  esac
}

install_mac_tool() {
  case $1 in
    brew)
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty ||
        fail "The Homebrew installer failed." "Install Homebrew from https://brew.sh, then re-run setup."
      refresh_path
      ;;
    git) brew install git </dev/null ;;
    node)
      brew install node@24 </dev/null
      brew link --overwrite --force node@24 </dev/null || warn "node@24 is installed but not linked; setup puts it on PATH for this run and for the worker"
      ;;
    python) brew install python@3.11 </dev/null ;;
    ffmpeg) brew install ffmpeg </dev/null ;;
    gh) brew install gh </dev/null ;;
    aws) brew install awscli </dev/null ;;
    claude) install_claude ;;
  esac
}

plan_satisfied() {
  case $1 in
    brew) have brew ;;
    base) have curl && have unzip && have gpg ;;
    git) have git ;;
    node) [ -n "$(node_major)" ] && [ "$(node_major)" -ge 24 ] ;;
    python) [ -n "$(python311)" ] ;;
    ffmpeg) have ffmpeg && have ffprobe ;;
    gh) have gh ;;
    aws) have aws ;;
    claude) have claude ;;
  esac
}

install_tools() {
  local key label why
  step "3/7 Tools"
  build_plan
  if [ -z "$PLAN" ]; then
    ok "no tools to install"
  else
    info "Setup will install:"
    while IFS='|' read -r key label why; do
      if [ -n "$key" ]; then info "  - $(plan_line "$key")   [$why]"; fi
    done <<<"$PLAN"
  fi
  info "Step 5 also installs, inside the work folder and the engine: npm packages (npm ci),"
  info "Playwright Chromium, the TTS Python env (PyTorch CUDA or CPU wheels) and the voice models (once)."
  if [ -z "$PLAN" ]; then return 0; fi
  if [ "$DRY_RUN" = 1 ]; then dry "nothing installed (dry run)"; return 0; fi
  if [ "$PLATFORM" = linux ] && ! have apt-get; then
    fail "This Linux has no apt-get; setup only installs tools on Debian and Ubuntu." "Install the tools listed above yourself, then re-run setup."
  fi
  if ! ask_yes_no "Install these now?" y; then fail "Nothing was installed." "Install the tools listed above yourself, or re-run setup and answer y."; fi

  # The plan comes in on fd 3, so an installer that reads stdin can't eat it.
  while IFS='|' read -r key label why <&3; do
    if [ -z "$key" ]; then continue; fi
    running "$(plan_line "$key")"
    if [ "$PLATFORM" = mac ]; then install_mac_tool "$key"; else install_linux_tool "$key"; fi
    refresh_path
  done 3<<<"$PLAN"
  while IFS='|' read -r key label why; do
    if [ -z "$key" ]; then continue; fi
    if ! plan_satisfied "$key"; then
      fail "$label was installed, but this shell can't find it yet." "Open a new terminal and run setup again."
    fi
    ok "$label installed"
  done <<<"$PLAN"
}

# ------------------------------------------------------------------ 4. logins

confirm_github() {
  local status scopes missing="" s
  if ! have gh; then dry "GitHub: would log in with gh auth login -s $GH_SCOPES (gh is not installed yet)"; return 0; fi
  # The status output holds a masked token, so it is only matched here and never printed.
  if status=$(gh auth status --hostname github.com 2>&1 </dev/null); then
    scopes=$(printf '%s\n' "$status" | sed -n "s/.*Token scopes: //p" | head -n 1 | tr -d "' ")
    status=""
    if [ -n "$scopes" ]; then
      for s in repo project read:org; do
        case ",$scopes," in *",$s,"*) ;; *) missing="$missing $s" ;; esac
      done
    fi
    if [ -z "$missing" ]; then
      ok "GitHub: logged in"
    elif [ "$DRY_RUN" = 1 ]; then
      dry "GitHub: would add the missing scopes$missing (gh auth refresh)"
    else
      todo "GitHub: the login lacks the scopes$missing; approving them in the browser"
      gh auth refresh --hostname github.com --scopes "$GH_SCOPES" </dev/tty ||
        fail "GitHub: could not add the scopes." "Run 'gh auth refresh -h github.com -s $GH_SCOPES' yourself, then re-run setup."
      ok "GitHub: scopes added"
    fi
  elif [ "$DRY_RUN" = 1 ]; then
    dry "GitHub: not logged in; would run gh auth login -s $GH_SCOPES"
    return 0
  else
    todo "GitHub: not logged in. Log in with the GitHub account the owner added to the arkiova org."
    gh auth login --hostname github.com --git-protocol https --web --scopes "$GH_SCOPES" </dev/tty ||
      fail "GitHub: the login did not finish." "Run 'gh auth login -s $GH_SCOPES' yourself, then re-run setup."
    ok "GitHub: logged in"
  fi
  if [ "$DRY_RUN" != 1 ]; then
    # Lets plain git (pull, fetch) use the gh login for github.com.
    gh auth setup-git --hostname github.com >/dev/null 2>&1 </dev/null || true
  fi
}

aws_profile_ok() {
  local out
  # The output holds masked keys, so it is only matched here and never printed.
  if ! out=$(aws configure list --profile "$AWS_PROFILE_NAME" 2>&1 </dev/null); then return 1; fi
  if printf '%s\n' "$out" | grep -Eq '(access_key|secret_key|region)[[:space:]]+<not set>'; then return 1; fi
  return 0
}

# Reads the discovery parameter: sets API_URL, or DISCOVERY_WHY (a short reason) and returns 1.
read_discovery() {
  local out
  if out=$(aws ssm get-parameter --name "$SSM_PARAMETER" --profile "$AWS_PROFILE_NAME" --query Parameter.Value --output text 2>&1 </dev/null); then
    API_URL=$(printf '%s' "$out" | sed -n 's/.*"apiUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    return 0
  fi
  # Only a short reason is kept: AWS error text can include the account id.
  case $out in
    *"Unable to locate credentials"*) DISCOVERY_WHY="no credentials" ;;
    *"specify a region"*) DISCOVERY_WHY="no region set" ;;
    *"Could not connect"* | *"Connect timeout"*) DISCOVERY_WHY="no connection to AWS" ;;
    *"when calling"*) DISCOVERY_WHY=$(printf '%s\n' "$out" | sed -n 's/.*(\([A-Za-z]*\)) when calling.*/\1/p' | head -n 1) ;;
    *) DISCOVERY_WHY="the AWS CLI failed" ;;
  esac
  out=""
  return 1
}

confirm_aws() {
  if ! have aws; then dry "AWS: would set up the profile $AWS_PROFILE_NAME (the AWS CLI is not installed yet)"; return 0; fi
  if ! aws_profile_ok; then
    if [ "$DRY_RUN" = 1 ]; then
      dry "AWS: profile $AWS_PROFILE_NAME is missing or incomplete; would run aws configure --profile $AWS_PROFILE_NAME"
      return 0
    fi
    todo "AWS: the profile $AWS_PROFILE_NAME is missing or incomplete."
    info "The key comes from the owner: they create an access key for the IAM user $AWS_IAM_USER"
    info "(IAM > Users > $AWS_IAM_USER > Security credentials > Create access key) and"
    info "send you the access key ID, the secret access key and the region, over a private channel."
    info "Type them into the prompts below; press Enter for the output format. The AWS CLI keeps"
    info "them in its own files (~/.aws); this script never reads, prints or stores them."
    aws configure --profile "$AWS_PROFILE_NAME" </dev/tty || true
    if ! aws_profile_ok; then
      fail "AWS: the profile $AWS_PROFILE_NAME is still incomplete." "Run 'aws configure --profile $AWS_PROFILE_NAME' with the key and region the owner sent, then re-run setup."
    fi
  fi
  if read_discovery; then
    ok "AWS: profile $AWS_PROFILE_NAME reads $SSM_PARAMETER"
  elif [ "$DRY_RUN" = 1 ]; then
    warn "AWS: profile $AWS_PROFILE_NAME is set but can't read $SSM_PARAMETER ($DISCOVERY_WHY)"
  else
    fail "AWS: profile $AWS_PROFILE_NAME can't read $SSM_PARAMETER ($DISCOVERY_WHY)." "Check the key and region with the owner, run 'aws configure --profile $AWS_PROFILE_NAME' again, then re-run setup."
  fi
}

claude_logged_in() { claude auth status >/dev/null 2>&1 </dev/null; }

confirm_claude() {
  if ! have claude; then dry "Claude Code: would ask you to log in (claude is not installed yet)"; return 0; fi
  if claude_logged_in; then ok "Claude Code: logged in"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then dry "Claude Code: not logged in; would ask you to run claude and log in, then wait"; return 0; fi
  todo "Claude Code: not logged in."
  info "Open another terminal, run:  claude   and log in with the Claude account for the label '$CFG_ACCOUNT'."
  info "Then come back here."
  while ! claude_logged_in; do
    ask_tty "    Press Enter once you have logged in (or type q to stop): "
    case $REPLY_TEXT in q* | Q*) fail "Claude Code is not logged in." "Run claude, log in, then re-run setup." ;; esac
    if ! claude_logged_in; then warn "still not logged in"; fi
  done
  ok "Claude Code: logged in"
}

# ------------------------------------------------------------------ 5. code and dependencies

worker_running() {
  if [ "$PLATFORM" = linux ]; then
    systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null
  else
    launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1
  fi
}

# The worker holds files open in node_modules and the TTS env, so it stops before they change.
pause_worker() {
  if [ "$WORKER_STOPPED" = 1 ] || ! worker_running; then return 0; fi
  WORKER_STOPPED=1
  if [ "$DRY_RUN" = 1 ]; then dry "would stop the running worker first and start it again at the end"; return 0; fi
  running "stopping the running worker while its files change (it starts again at the end)"
  if [ "$PLATFORM" = linux ]; then
    systemctl --user stop "$SERVICE_NAME"
  else
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
  fi
}

resume_worker() {
  local started=1
  if [ "$WORKER_STOPPED" != 1 ] || [ "$DRY_RUN" = 1 ]; then return 0; fi
  if [ "$PLATFORM" = linux ]; then
    if [ -f "$(unit_file)" ] && ! systemctl --user start "$SERVICE_NAME"; then started=0; fi
  elif [ -f "$(plist_file)" ] && ! worker_running; then
    if ! launchctl bootstrap "gui/$(id -u)" "$(plist_file)"; then started=0; fi
  fi
  if [ "$started" = 1 ]; then ok "worker started again"; else warn "could not start the worker again; it starts at the next log-in"; fi
}

sync_repo() {
  local repo=$1 dir=$2 before after
  if [ -d "$dir/.git" ]; then
    if [ "$DRY_RUN" = 1 ]; then dry "would update $dir from $repo (git pull --ff-only)"; return 0; fi
    before=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)
    if ! git -C "$dir" symbolic-ref -q HEAD >/dev/null 2>&1; then
      git -C "$dir" fetch --quiet </dev/null || true
      ok "$repo is at a pinned commit; fetched, not moved"
      return 0
    fi
    git -C "$dir" pull --ff-only --quiet </dev/null ||
      fail "Could not update $dir." "Look at it with 'git -C \"$dir\" status', commit, stash or discard the local changes (or delete the folder), then re-run setup."
    after=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)
    if [ "$before" = "$after" ]; then ok "$repo is up to date ($after)"; else ok "$repo updated $before -> $after"; fi
    return 0
  fi
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    fail "$dir exists but is not a git clone." "Move or delete that folder, then re-run setup."
  fi
  if [ "$DRY_RUN" = 1 ]; then dry "would clone $repo into $dir"; return 0; fi
  running "cloning $repo into $dir"
  gh repo clone "$repo" "$dir" -- --quiet </dev/null ||
    fail "Could not clone $repo." "Check that your GitHub account can see $repo (ask the owner for access), then re-run setup."
  ok "cloned $repo"
}

npm_current() {
  local lock="$1/package-lock.json" stamp="$1/node_modules/$STAMP_NAME"
  [ -f "$lock" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(file_hash "$lock")" ]
}

install_npm() {
  local dir=$1 label=$2
  if npm_current "$dir"; then ok "$label npm packages are current"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then dry "would run npm ci in $dir"; return 0; fi
  if [ ! -f "$dir/package-lock.json" ]; then
    fail "$dir has no package-lock.json, so npm ci can't run." "Tell the owner that $label needs a committed package-lock.json."
  fi
  pause_worker
  running "npm ci in $dir"
  (cd "$dir" && npm ci --no-audit --no-fund </dev/null) ||
    fail "npm ci failed in $dir." "Read the npm error above; a network hiccup just needs a re-run. Then re-run setup."
  file_hash "$dir/package-lock.json" >"$dir/node_modules/$STAMP_NAME"
  ok "$label npm packages installed"
}

install_chromium() {
  local engine=$1 flags="chromium"
  # On Linux, --with-deps also installs the system libraries Chromium needs (through sudo).
  if [ "$PLATFORM" = linux ]; then flags="--with-deps chromium"; fi
  if [ "$DRY_RUN" = 1 ]; then dry "would run npx playwright install $flags in $engine (a no-op when it is already there)"; return 0; fi
  running "npx playwright install $flags"
  if [ "$PLATFORM" = linux ]; then
    (cd "$engine" && npx playwright install --with-deps chromium </dev/tty) ||
      fail "Playwright could not install Chromium." "Run 'npx playwright install --with-deps chromium' in $engine to see why, then re-run setup."
  else
    (cd "$engine" && npx playwright install chromium </dev/null) ||
      fail "Playwright could not install Chromium." "Run 'npx playwright install chromium' in $engine to see why, then re-run setup."
  fi
  ok "Playwright Chromium is installed"
}

requirement_pin() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*==[[:space:]]*\([A-Za-z0-9.+]*\).*/\1/p" "$1" | head -n 1
}

stamp_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 || true; }

download_voice_models() {
  local engine=$1 python=$2
  # Downloads what the engine's first TTS run would, with the engine's own code: the
  # Chatterbox weights (its from_pretrained, stopped before the model loads), the
  # whisper-tiny.en speech check and torchaudio's MMS_FA word aligner.
  (cd "$engine" && PYTHONUTF8=1 "$python" - "$engine" <<'PY'
import os, sys
engine = sys.argv[1]
sys.path.insert(0, os.path.join(engine, "tts", "src"))
from chatterbox import mtl_tts
cls = mtl_tts.ChatterboxMultilingualTTS
cls.from_local = classmethod(lambda c, ckpt_dir, device: ckpt_dir)
print("voice model:", cls.from_pretrained("cpu"), flush=True)
from transformers import pipeline
pipeline("automatic-speech-recognition", model="openai/whisper-tiny.en", device=-1)
print("speech check: openai/whisper-tiny.en", flush=True)
import torchaudio
torchaudio.pipelines.MMS_FA.get_model(with_star=False)
print("word aligner: torchaudio MMS_FA", flush=True)
PY
  ) || fail "Could not download the voice models." "Check the network (Hugging Face and download.pytorch.org must be reachable), then re-run setup."
}

install_tts() {
  local engine=$1 venv req python stamp variant index cuda_index torch torchaudio req_hash
  local venv_exists=0 deps_current=0 models_done=0 models_flag wheel_note py311
  case ",$CFG_CAPS," in *,tts,*) ;; *) ok "TTS env skipped: this worker has no tts capability"; return 0 ;; esac
  venv="$engine/tts/.venv"
  req="$engine/tts/requirements.txt"
  python="$venv/bin/python"
  stamp="$venv/$STAMP_NAME"
  if [ "$PLATFORM" = mac ]; then variant=mps; elif [ "$HAS_GPU" = 1 ]; then variant=cuda; else variant=cpu; fi
  if [ ! -f "$req" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      dry "would create $venv with Python 3.11 and install tts/requirements.txt (PyTorch $variant wheels)"
      dry "would download the voice models once (about 4.5 GB)"
      return 0
    fi
    fail "The engine has no tts/requirements.txt ($req)." "Update the engine (re-run setup) or ask the owner."
  fi
  if [ "$PLATFORM" = mac ] && [ "$(uname -m)" != arm64 ]; then
    fail "PyTorch $(requirement_pin "$req" torch) has no wheels for Intel Macs, so this Mac can't run TTS." "Re-run setup and set capabilities to agent,render."
  fi
  torch=$(requirement_pin "$req" torch)
  torchaudio=$(requirement_pin "$req" torchaudio)
  cuda_index=$(sed -n 's/^[[:space:]]*--\(extra-\)\{0,1\}index-url[[:space:]]*\(https:\/\/download\.pytorch\.org\/whl\/cu[0-9]*\).*/\2/p' "$req" | head -n 1)
  cuda_index=${cuda_index:-https://download.pytorch.org/whl/cu126}
  case $variant in
    cuda) index=$cuda_index; wheel_note="PyTorch $torch CUDA wheels from $index (NVIDIA GPU found)" ;;
    cpu) index=https://download.pytorch.org/whl/cpu; wheel_note="PyTorch $torch CPU wheels (no NVIDIA GPU)" ;;
    *) index=""; wheel_note="PyTorch $torch from PyPI (Apple silicon)" ;;
  esac
  req_hash=$(file_hash "$req")
  if [ -x "$python" ]; then venv_exists=1; fi
  if [ "$venv_exists" = 1 ] && [ "$(stamp_get "$stamp" requirements)" = "$req_hash" ] && [ "$(stamp_get "$stamp" torch)" = "$variant" ]; then deps_current=1; fi
  if [ "$venv_exists" = 1 ] && [ "$(stamp_get "$stamp" models)" = true ]; then models_done=1; fi

  if [ "$deps_current" = 1 ]; then
    ok "TTS env is current ($venv, $variant)"
  elif [ "$DRY_RUN" = 1 ]; then
    if [ "$venv_exists" = 1 ]; then dry "would update $venv: $wheel_note, then tts/requirements.txt"; else dry "would create $venv with Python 3.11: $wheel_note, then tts/requirements.txt"; fi
  else
    pause_worker
    if [ "$venv_exists" != 1 ]; then
      py311=$(python311)
      if [ -z "$py311" ]; then fail "Python 3.11 is not installed." "Re-run setup so it installs Python 3.11."; fi
      running "creating $venv with Python 3.11"
      "$py311" -m venv "$venv" </dev/null || fail "Could not create $venv." "Delete $venv if it is half made, then re-run setup."
    fi
    "$python" -m pip --disable-pip-version-check --no-input install --upgrade pip </dev/null || true
    if [ -n "$torch" ]; then
      set -- install "torch==$torch"
      if [ -n "$torchaudio" ]; then set -- "$@" "torchaudio==$torchaudio"; fi
      if [ -n "$index" ]; then set -- "$@" --index-url "$index" --extra-index-url https://pypi.org/simple; fi
      # A venv built before (or for the other device) is switched in place.
      if [ "$venv_exists" = 1 ] && [ "$(stamp_get "$stamp" torch)" != "$variant" ]; then set -- "$@" --force-reinstall --no-deps; fi
      running "installing $wheel_note"
      "$python" -m pip --disable-pip-version-check --no-input "$@" </dev/null ||
        fail "Could not install PyTorch." "Read the pip error above (often the network), then re-run setup."
    fi
    running "installing tts/requirements.txt"
    (cd "$engine" && "$python" -m pip --disable-pip-version-check --no-input install -r "$req" </dev/null) ||
      fail "Could not install the TTS requirements." "Read the pip error above, then re-run setup."
    models_flag=false
    if [ "$models_done" = 1 ]; then models_flag=true; fi
    printf 'requirements=%s\ntorch=%s\nmodels=%s\n' "$req_hash" "$variant" "$models_flag" >"$stamp"
    ok "TTS env ready ($variant)"
  fi

  if [ "$models_done" = 1 ]; then
    ok "voice models already downloaded"
  elif [ "$DRY_RUN" = 1 ]; then
    dry "would download the voice models once: Chatterbox, whisper-tiny.en and the MMS_FA aligner (about 4.5 GB, in your user cache)"
  else
    running "downloading the voice models once (about 4.5 GB; this takes a while)"
    download_voice_models "$engine" "$python"
    printf 'requirements=%s\ntorch=%s\nmodels=true\n' "$req_hash" "$variant" >"$stamp"
    ok "voice models downloaded"
  fi
}

# ------------------------------------------------------------------ 6. config, doctor, dry pass

config_text() {
  printf '{\n'
  printf '  "name": %s,\n' "$(json_str "$CFG_NAME")"
  printf '  "capabilities": %s,\n' "$(json_list "$CFG_CAPS")"
  printf '  "ttsDevice": %s,\n' "$(json_str "$CFG_DEVICE")"
  printf '  "maxJobs": %s,\n' "$CFG_JOBS"
  printf '  "workDir": %s,\n' "$(json_str "$CFG_WORK_DIR")"
  printf '  "enginePath": %s,\n' "$(json_str "$CFG_ENGINE")"
  printf '  "awsProfile": %s,\n' "$(json_str "$AWS_PROFILE_NAME")"
  printf '  "claudeAccount": %s,\n' "$(json_str "$CFG_ACCOUNT")"
  printf '  "repos": %s,\n' "$(json_list "$CFG_REPOS")"
  printf '  "cacheBudgetGB": %s,\n' "$CFG_CACHE"
  printf '  "pollSeconds": %s\n' "$CFG_POLL"
  printf '}\n'
}

# Node merges the new values into the existing file: keys it doesn't know are kept, and
# a file whose values already match is left alone. It prints unchanged, dry or written.
readonly NODE_WRITE_CONFIG='
const fs = require("fs");
const [path, text] = process.argv.slice(1);
const want = JSON.parse(text);
let old = null;
try { old = JSON.parse(fs.readFileSync(path, "utf8")); } catch (e) { old = null; }
const out = Object.assign({}, want);
if (old) for (const k of Object.keys(old)) if (!(k in out)) out[k] = old[k];
const keys = Object.keys(out);
if (old && JSON.stringify(keys.map((k) => old[k])) === JSON.stringify(keys.map((k) => out[k]))) { console.log("unchanged"); process.exit(0); }
const extra = keys.filter((k) => !(k in want)).map((k) => ",\n  " + JSON.stringify(k) + ": " + JSON.stringify(out[k])).join("");
const body = text.trimEnd().replace(/\n}$/, extra + "\n}") + "\n";
if (process.env.STARTER_DRY === "1") { console.log("dry"); process.stdout.write(body); process.exit(0); }
fs.mkdirSync(require("path").dirname(path), { recursive: true });
fs.writeFileSync(path, body);
console.log("written");
'

studio_entry() {
  local dir="$1/studio"
  if [ ! -f "$dir/package.json" ] || ! have node; then return 0; fi
  node -e 'const p=require(process.argv[1]);const b=typeof p.bin==="string"?p.bin:(p.bin||{}).studio;if(b)process.stdout.write(require("path").join(process.argv[2],b))' "$dir/package.json" "$dir" 2>/dev/null || true
}

# `studio setup` writes the config itself when it takes every setting as a flag; the help is
# read with no terminal input, so a version without those flags can't stop to ask.
studio_setup_has_flags() {
  local entry=$1 help flag
  help=$(cd "$CFG_WORK_DIR" && node "$entry" setup --help 2>&1 </dev/null) || return 1
  for flag in --name --capabilities --tts-device --max-jobs --work-dir --engine-path --aws-profile --claude-account --repos --cache-budget-gb --poll-seconds; do
    case $help in *"$flag"*) ;; *) return 1 ;; esac
  done
  return 0
}

write_config() {
  local path="$CFG_WORK_DIR/$CONFIG_NAME" text result entry line
  text=$(config_text)
  if ! have node; then
    # Only in a dry run: a real run has installed Node by now.
    dry "would write $path"
    while IFS= read -r line; do info "        $line"; done <<<"$text"
    return 0
  fi
  result=$(STARTER_DRY=1 node -e "$NODE_WRITE_CONFIG" "$path" "$text") || fail "Could not read $path." "Fix or delete it, then re-run setup."
  if [ "$result" = unchanged ]; then ok "$path is unchanged"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then
    dry "would write $path"
    result=${result#dry}
    result=${result#$'\n'}
    while IFS= read -r line; do info "        $line"; done <<<"$result"
    return 0
  fi
  entry=$(studio_entry "$CFG_WORK_DIR")
  if [ -n "$entry" ] && studio_setup_has_flags "$entry"; then
    # --yes: take the flags instead of asking again. studio setup also writes a pointer in
    # the home folder, so `studio` finds this config from any folder.
    # --repos= (empty): the worker serves every repo tagged arkiova-studio, and an old list is cleared.
    running "studio setup (writes the config)"
    (cd "$CFG_WORK_DIR" && node "$entry" setup --yes --name "$CFG_NAME" --capabilities "$CFG_CAPS" --tts-device "$CFG_DEVICE" \
      --max-jobs "$CFG_JOBS" --work-dir "$CFG_WORK_DIR" --engine-path "$CFG_ENGINE" --aws-profile "$AWS_PROFILE_NAME" \
      --claude-account "$CFG_ACCOUNT" "--repos=$CFG_REPOS" --cache-budget-gb "$CFG_CACHE" --poll-seconds "$CFG_POLL" </dev/null) ||
      fail "studio setup failed." "Read its error above, fix it, then re-run setup."
  else
    STARTER_DRY=0 node -e "$NODE_WRITE_CONFIG" "$path" "$text" >/dev/null ||
      fail "Could not write $path." "Check that you can write to $CFG_WORK_DIR, then re-run setup."
  fi
  ok "wrote $path"
}

studio_checks() {
  local entry
  if [ "$DRY_RUN" = 1 ]; then
    dry "would run: studio doctor"
    dry "would run: studio worker --once --dry"
    return 0
  fi
  entry=$(studio_entry "$CFG_WORK_DIR")
  if [ -z "$entry" ]; then
    fail "The studio clone has no 'studio' command (package.json bin)." "Re-run setup to update the clone, or ask the owner whether the worker CLI is published yet."
  fi
  running "studio doctor"
  (cd "$CFG_WORK_DIR" && node "$entry" doctor --config "$CFG_WORK_DIR/$CONFIG_NAME" </dev/null) ||
    fail "studio doctor found a problem (see above)." "Fix what it reports, then re-run setup."
  ok "studio doctor passed"
  running "studio worker --once --dry"
  (cd "$CFG_WORK_DIR" && node "$entry" worker --once --dry --config "$CFG_WORK_DIR/$CONFIG_NAME" </dev/null) ||
    fail "The dry worker pass failed (see above)." "Fix what it reports, then re-run setup."
  ok "dry worker pass finished"
}

# ------------------------------------------------------------------ 7. autostart

runner_text() {
  cat <<'EOF'
#!/bin/sh
# Arkiova Studio worker runner.
# Written by setup.sh (arkiova/studio-starter), which rewrites it, so don't edit it.
# Started by the systemd --user unit arkiova-studio-worker (Linux) or the launchd agent
# com.arkiova.studio-worker (macOS). It runs `studio worker` from the studio clone next to
# it, with this folder as the working directory, and logs to ./logs (the newest 30 runs are kept).
cd "$(dirname "$0")" || exit 1
mkdir -p logs
stamp=$(date +%Y%m%d-%H%M%S)
find logs -maxdepth 1 -name 'worker-*.log' -type f | sort -r | tail -n +31 | while IFS= read -r old; do rm -f "$old"; done
bin=$(node -e 'const p=require(process.argv[1]);const b=typeof p.bin==="string"?p.bin:(p.bin||{}).studio;if(!b)process.exit(1);process.stdout.write(b)' "$PWD/studio/package.json") || {
  echo "$(date) the studio clone has no studio command" >>logs/runner.log
  exit 1
}
exec node "studio/$bin" worker --config "$PWD/studio.worker.json" >>"logs/worker-$stamp.log" 2>&1
EOF
}

unit_text() {
  local dir=$1
  cat <<EOF
[Unit]
Description=Arkiova Studio worker (set up by arkiova/studio-starter)
After=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=4

[Service]
Type=simple
WorkingDirectory=${dir//\%/%%}
Environment="PATH=${PATH//\%/%%}"
ExecStart=/bin/sh "${dir//\%/%%}/$RUNNER_NAME"
Restart=on-failure
RestartSec=60
# SIGINT is the worker's Ctrl+C: it stops claiming and finishes what it runs, for up to a minute.
KillSignal=SIGINT
TimeoutStopSec=60

[Install]
WantedBy=default.target
EOF
}

plist_text() {
  local dir
  dir=$(xml_escape "$1")
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$dir/$RUNNER_NAME</string></array>
  <key>WorkingDirectory</key><string>$dir</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(xml_escape "$PATH")</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
}

setup_autostart() {
  local dir=$CFG_WORK_DIR runner file text runner_same=0 file_same=0
  runner="$dir/$RUNNER_NAME"
  if [ "$PLATFORM" = linux ]; then file=$(unit_file); text=$(unit_text "$dir"); else file=$(plist_file); text=$(plist_text "$dir"); fi
  if [ -f "$runner" ] && [ "$(cat "$runner")" = "$(runner_text)" ]; then runner_same=1; fi
  if [ -f "$file" ] && [ "$(cat "$file")" = "$text" ]; then file_same=1; fi

  if [ "$runner_same" = 1 ] && [ "$file_same" = 1 ]; then
    ok "autostart is already set up ($file)"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    dry "would write $runner"
    if [ "$PLATFORM" = linux ]; then
      dry "would write $file and enable it: a systemd --user unit that starts at log-in,"
      dry "restarts on failure 3 times 1 minute apart, and logs in $dir/logs"
    else
      dry "would write $file and load it: a launchd agent that starts at log-in, restarts"
      dry "after a failure (at most once a minute), and logs in $dir/logs"
    fi
    return 0
  fi
  mkdir -p "$dir/logs"
  if [ "$runner_same" != 1 ]; then runner_text >"$runner"; chmod +x "$runner"; fi
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$text" >"$file"
  if [ "$PLATFORM" = linux ]; then
    if ! systemctl --user daemon-reload 2>/dev/null; then
      fail "systemd --user is not available here (WSL without systemd, or a container?)." "Re-run setup with --no-autostart and start the worker yourself: sh \"$runner\""
    fi
    systemctl --user enable "$SERVICE_NAME" >/dev/null 2>&1 || fail "Could not enable $SERVICE_NAME." "Run 'systemctl --user enable $SERVICE_NAME' to see why, then re-run setup."
    ok "systemd --user unit $SERVICE_NAME enabled: starts at log-in, restarts on failure 3 times 1 minute apart"
    # A new or changed unit starts now rather than at the next log-in (unless setup stopped
    # the worker earlier; it is started again at the end).
    if [ "$WORKER_STOPPED" != 1 ]; then
      if systemctl --user restart "$SERVICE_NAME"; then ok "worker started"; else warn "could not start the worker now; it starts at the next log-in"; fi
    fi
  else
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
    if [ "$WORKER_STOPPED" = 1 ]; then WORKER_STOPPED=0; fi
    launchctl bootstrap "gui/$(id -u)" "$file" || fail "Could not load $file." "Run 'launchctl bootstrap gui/$(id -u) \"$file\"' to see why, then re-run setup."
    ok "launchd agent $LAUNCHD_LABEL loaded: starts at log-in, restarts after a failure"
  fi
}

# ------------------------------------------------------------------ uninstall

is_worker_folder() {
  local dir=$1 marker
  case $dir in / | "$HOME" | "$HOME/") return 1 ;; esac
  if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then return 0; fi
  for marker in "$CONFIG_NAME" "$RUNNER_NAME" studio motion-agent logs; do
    if [ -e "$dir/$marker" ]; then return 0; fi
  done
  return 1
}

uninstall() {
  local dir file
  step "Uninstall"
  dir=${WORK_DIR:-$(existing_work_dir)}
  dir=${dir%/}
  if [ "$PLATFORM" = linux ]; then file=$(unit_file); else file=$(plist_file); fi
  if [ ! -f "$file" ]; then
    ok "no autostart ($file)"
  elif [ "$DRY_RUN" = 1 ]; then
    dry "would stop the worker and remove $file"
  else
    if [ "$PLATFORM" = linux ]; then
      systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
      rm -f "$file"
      systemctl --user daemon-reload 2>/dev/null || true
    else
      launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
      rm -f "$file"
    fi
    ok "removed the autostart ($file)"
  fi

  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    ok "no work folder found"
  elif ! is_worker_folder "$dir"; then
    fail "$dir does not look like a worker folder, so setup won't delete it." "Delete it yourself if you are sure, or pass the right --work-dir."
  elif [ "$DRY_RUN" = 1 ]; then
    dry "would ask, then delete $dir (clones, cache, logs, config)"
  elif ask_yes_no "Delete $dir and everything in it (clones, cache, logs, config)?" n; then
    rm -rf -- "$dir" || fail "Could not delete all of $dir." "Close anything using it, then delete it yourself."
    ok "deleted $dir"
  else
    ok "kept $dir"
  fi
  info "The tools, the logins and the AWS profile stay installed. An engine checkout given with --engine-path is never touched."
}

# ------------------------------------------------------------------ main

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --yes | -y) YES=1 ;;
      --no-autostart) NO_AUTOSTART=1 ;;
      --uninstall) UNINSTALL=1 ;;
      --work-dir | --name | --engine-path)
        if [ $# -lt 2 ]; then fail "$1 needs a value." "Run setup with --help to see the options."; fi
        case $1 in
          --work-dir) WORK_DIR=$2 ;;
          --name) NAME=$2 ;;
          --engine-path) ENGINE_PATH=$2 ;;
        esac
        shift
        ;;
      --work-dir=*) WORK_DIR=${1#*=} ;;
      --name=*) NAME=${1#*=} ;;
      --engine-path=*) ENGINE_PATH=${1#*=} ;;
      -h | --help) usage; exit 0 ;;
      *) fail "Unknown option $1." "Run setup with --help to see the options." ;;
    esac
    shift
  done
  # --work-dir=~/x reaches us with the tilde unexpanded.
  case $WORK_DIR in \~/*) WORK_DIR="$HOME/${WORK_DIR#\~/}" ;; esac
  case $ENGINE_PATH in \~/*) ENGINE_PATH="$HOME/${ENGINE_PATH#\~/}" ;; esac
}

setup() {
  local studio_dir
  show_hardware
  read_settings
  install_tools

  step "4/7 Logins"
  confirm_github
  confirm_aws
  confirm_claude

  step "5/7 Code and dependencies"
  if [ "$DRY_RUN" != 1 ]; then mkdir -p "$CFG_WORK_DIR"; fi
  studio_dir="$CFG_WORK_DIR/studio"
  sync_repo "$STUDIO_REPO" "$studio_dir"
  if [ "$ENGINE_MANAGED" = 1 ]; then sync_repo "$ENGINE_REPO" "$CFG_ENGINE"; else ok "engine: using $CFG_ENGINE as it is (not pulled)"; fi
  install_npm "$studio_dir" studio
  install_npm "$CFG_ENGINE" engine
  install_chromium "$CFG_ENGINE"
  install_tts "$CFG_ENGINE"

  step "6/7 Worker config"
  write_config
  studio_checks

  step "7/7 Autostart"
  if [ "$NO_AUTOSTART" = 1 ]; then ok "skipped (--no-autostart)"; else setup_autostart; fi
  resume_worker

  step "Done"
  if [ "$DRY_RUN" = 1 ]; then info "Dry run: nothing was installed, cloned, written or registered."; fi
  info "$(printf '%-10s %s (%s), up to %s jobs' worker "$CFG_NAME" "$CFG_CAPS" "$CFG_JOBS")"
  info "$(printf '%-10s %s' config "$CFG_WORK_DIR/$CONFIG_NAME")"
  info "$(printf '%-10s %s' logs "$CFG_WORK_DIR/logs")"
  if [ -n "$API_URL" ]; then info "$(printf '%-10s %s/workers?t=<the workers link token from the owner>' workers "${API_URL%/}")"; fi
  if [ "$PLATFORM" = linux ]; then
    info "$(printf '%-10s %s' stop "systemctl --user stop $SERVICE_NAME")"
  else
    info "$(printf '%-10s %s' stop "launchctl bootout gui/\$(id -u)/$LAUNCHD_LABEL")"
  fi
  info "$(printf '%-10s %s' update 'run the same one-liner again')"
  info "$(printf '%-10s %s' uninstall "curl -fsSL $RAW_BASE/setup.sh | bash -s -- --uninstall")"
}

main() {
  parse_args "$@"
  case "$(uname -s)" in
    Linux) PLATFORM=linux ;;
    Darwin) PLATFORM=mac ;;
    *) fail "setup.sh is for Linux and macOS." "On Windows run in PowerShell: irm $RAW_BASE/setup.ps1 | iex" ;;
  esac
  refresh_path
  printf '\nArkiova Studio worker setup\n'
  if [ "$DRY_RUN" = 1 ]; then printf '%sDRY RUN: nothing will be installed, cloned, written or registered.%s\n' "$C_DRY" "$C_OFF"; fi
  if [ "$UNINSTALL" = 1 ]; then uninstall; else setup; fi
}

# Everything above only defines functions, so under curl | bash the whole script is read
# before anything runs. STUDIO_STARTER_NO_MAIN=1 loads the functions without running (for tests).
if [ "${STUDIO_STARTER_NO_MAIN:-}" != 1 ]; then main "$@"; fi
