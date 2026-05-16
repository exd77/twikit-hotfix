#!/usr/bin/env bash
set -euo pipefail

# One-command Twikit hotfix across projects.
# - Patches twikit/user.py and twikit/guest/user.py to use defensive .get() access
# - Replaces twikit/x_client_transaction/transaction.py from a known-good source
#
# Usage:
#   /home/ubuntu/twikit.sh
#   /home/ubuntu/twikit.sh --source /path/to/good/transaction.py
#   /home/ubuntu/twikit.sh --roots /home/ubuntu /root /opt/apps
#   /home/ubuntu/twikit.sh --non-interactive --roots /home/ubuntu/discord/follows-tracker
#   /home/ubuntu/twikit.sh --dry-run
#
# Notes:
# - Interactive by default when run from terminal.
# - Interactive mode provides numbered menu to pick target project(s).
# - Use --non-interactive for automation/cron.
# - Use --dry-run to preview planned changes without modifying files.

ROOTS=("/home/ubuntu" "/root")
SOURCE_TX=""
TS="$(date +%Y%m%d_%H%M%S)"
INTERACTIVE=1
DRY_RUN=0
USER_SET_SOURCE=0
USER_SET_ROOTS=0
PROGRESS_WIDTH=40
BLOCK_CHAR="█"
if ! locale charmap 2>/dev/null | grep -qi 'utf-8'; then
  BLOCK_CHAR="#"
fi

print_banner() {
  cat <<'EOF'

██████╗  █████╗ ████████╗ ██████╗██╗  ██╗    ████████╗██╗    ██╗██╗██╗  ██╗██╗████████╗    ███████╗██╗██╗  ██╗███████╗██████╗
██╔══██╗██╔══██╗╚══██╔══╝██╔════╝██║  ██║    ╚══██╔══╝██║    ██║██║██║ ██╔╝██║╚══██╔══╝    ██╔════╝██║╚██╗██╔╝██╔════╝██╔══██╗
██████╔╝███████║   ██║   ██║     ███████║       ██║   ██║ █╗ ██║██║█████╔╝ ██║   ██║       █████╗  ██║ ╚███╔╝ █████╗  ██║  ██║
██╔═══╝ ██╔══██║   ██║   ██║     ██╔══██║       ██║   ██║███╗██║██║██╔═██╗ ██║   ██║       ██╔══╝  ██║ ██╔██╗ ██╔══╝  ██║  ██║
██║     ██║  ██║   ██║   ╚██████╗██║  ██║       ██║   ╚███╔███╔╝██║██║  ██╗██║   ██║       ██║     ██║██╔╝ ██╗███████╗██████╔╝
╚═╝     ╚═╝  ╚═╝   ╚═╝    ╚═════╝╚═╝  ╚═╝       ╚═╝    ╚══╝╚══╝ ╚═╝╚═╝  ╚═╝╚═╝   ╚═╝       ╚═╝     ╚═╝╚═╝  ╚═╝╚══════╝╚═════╝

EOF
}

render_progress() {
  local current="$1"
  local total="$2"

  if [[ "$total" -le 0 ]]; then
    return
  fi

  local pct=$(( current * 100 / total ))
  local filled=$(( current * PROGRESS_WIDTH / total ))
  local empty=$(( PROGRESS_WIDTH - filled ))
  local bar_filled bar_empty
  bar_filled="$(printf '%*s' "$filled" '' | tr ' ' "$BLOCK_CHAR")"
  bar_empty="$(printf '%*s' "$empty" '' | tr ' ' ' ')"

  printf '[%s%s] %3d%%\n' "$bar_filled" "$bar_empty" "$pct"
}


while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_TX="$2"; USER_SET_SOURCE=1; shift 2;;
    --roots)
      shift
      ROOTS=()
      while [[ $# -gt 0 && "$1" != --* ]]; do
        ROOTS+=("$1")
        shift
      done
      USER_SET_ROOTS=1
      ;;
    --non-interactive)
      INTERACTIVE=0; shift;;
    --dry-run)
      DRY_RUN=1; shift;;
    -h|--help)
      sed -n '1,45p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

print_banner

discover_twikit_projects() {
  # Return unique project roots that contain twikit in venv site-packages.
  find "${ROOTS[@]}" -type f -path '*/venv/lib/python*/site-packages/twikit/user.py' 2>/dev/null \
    | sed -E 's#/venv/lib/python[^/]+/site-packages/twikit/user.py$##' \
    | awk '!seen[$0]++'
}

if [[ $INTERACTIVE -eq 1 && -t 0 ]]; then
  echo "[INPUT] Twikit hotfix settings"

  if [[ $USER_SET_ROOTS -eq 0 ]]; then
    echo
    echo "Pilih target patch:"
    echo "  1) Scan default roots: ${ROOTS[*]}"
    echo "  2) Pilih 1 project (detected list)"
    echo "  3) Pilih multiple project (detected list)"
    echo "  4) Input manual root directories (FAST)"

    read -r -p "Menu number (Enter=1): " menu_choice || true
    menu_choice="${menu_choice:-1}"

    case "$menu_choice" in
      1)
        ;;
      2|3)
        echo "[INFO] Scanning detected projects under: ${ROOTS[*]} (please wait)"
        mapfile -t DETECTED_PROJECTS < <(discover_twikit_projects || true)
        if [[ ${#DETECTED_PROJECTS[@]} -eq 0 ]]; then
          echo "[ERR] No detected Twikit projects found under: ${ROOTS[*]}" >&2
          exit 1
        fi

        echo
        echo "Detected projects:"
        idx=1
        for p in "${DETECTED_PROJECTS[@]}"; do
          echo "   [$idx] $p"
          idx=$((idx + 1))
        done

        if [[ "$menu_choice" == "2" ]]; then
          read -r -p "Project number: " pick_one
          if [[ "$pick_one" =~ ^[0-9]+$ ]] && (( pick_one >= 1 && pick_one <= ${#DETECTED_PROJECTS[@]} )); then
            ROOTS=("${DETECTED_PROJECTS[$((pick_one-1))]}")
          else
            echo "[ERR] Invalid project number: $pick_one" >&2
            exit 1
          fi
        else
          read -r -p "Project numbers (e.g. 1,3,5): " pick_many
          pick_many="${pick_many//,/ }"
          ROOTS=()
          for n in $pick_many; do
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#DETECTED_PROJECTS[@]} )); then
              ROOTS+=("${DETECTED_PROJECTS[$((n-1))]}")
            else
              echo "[ERR] Invalid project number: $n" >&2
              exit 1
            fi
          done
          if [[ ${#ROOTS[@]} -eq 0 ]]; then
            echo "[ERR] No project selected" >&2
            exit 1
          fi
          mapfile -t ROOTS < <(printf '%s\n' "${ROOTS[@]}" | awk '!seen[$0]++')
        fi
        ;;
      4)
        read -r -p "Manual roots (space-separated): " input_roots
        if [[ -z "${input_roots:-}" ]]; then
          echo "[ERR] Manual roots cannot be empty" >&2
          exit 1
        fi
        ROOTS=()
        read -r -a ROOTS <<< "$input_roots"
        ;;
      *)
        echo "[ERR] Invalid menu: $menu_choice" >&2
        exit 1
        ;;
    esac
  fi

  if [[ $USER_SET_SOURCE -eq 0 ]]; then
    echo
    echo "Source transaction.py sekarang: ${SOURCE_TX:-<auto-discover>}"
    read -r -p "Source transaction.py path (Enter=auto-discover): " input_source || true
    if [[ -n "${input_source:-}" ]]; then
      SOURCE_TX="$input_source"
    fi
  fi
fi

if [[ -n "${SOURCE_TX:-}" && ! -f "$SOURCE_TX" ]]; then
  echo "[WARN] Source transaction.py not found at: $SOURCE_TX"
  echo "[INFO] Auto-discovering a fallback source..."
  SOURCE_TX=""
fi

if [[ -z "${SOURCE_TX:-}" ]]; then
  echo "[INFO] Auto-discovering transaction.py source from roots..."
  FALLBACK="$(find "${ROOTS[@]}" -type f -path '*/venv/lib/python*/site-packages/twikit/x_client_transaction/transaction.py' 2>/dev/null | head -n1 || true)"
  if [[ -z "$FALLBACK" ]]; then
    echo "[ERR] No transaction.py source found. Provide --source /path/to/transaction.py" >&2
    exit 1
  fi
  SOURCE_TX="$FALLBACK"
fi

echo "[INFO] Using transaction source: $SOURCE_TX"

declare -a USER_FILES
declare -a GUEST_USER_FILES
declare -a TX_FILES

while IFS= read -r f; do USER_FILES+=("$f"); done < <(find "${ROOTS[@]}" -type f -path '*/venv/lib/python*/site-packages/twikit/user.py' 2>/dev/null)
while IFS= read -r f; do GUEST_USER_FILES+=("$f"); done < <(find "${ROOTS[@]}" -type f -path '*/venv/lib/python*/site-packages/twikit/guest/user.py' 2>/dev/null)
while IFS= read -r f; do TX_FILES+=("$f"); done < <(find "${ROOTS[@]}" -type f -path '*/venv/lib/python*/site-packages/twikit/x_client_transaction/transaction.py' 2>/dev/null)

if [[ ${#USER_FILES[@]} -eq 0 && ${#GUEST_USER_FILES[@]} -eq 0 && ${#TX_FILES[@]} -eq 0 ]]; then
  echo "[ERR] No Twikit install found under roots: ${ROOTS[*]}" >&2
  exit 1
fi

total_steps=$(( ${#USER_FILES[@]} + ${#GUEST_USER_FILES[@]} + ${#TX_FILES[@]} ))
current_step=0
render_progress "$current_step" "$total_steps"

patch_user_file() {
  local file="$1"
  python3 - "$file" <<'PY'
import os, re, sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')

replacement = """        self.description_urls: list = legacy.get('entities', {}).get('description', {}).get('urls', [])
        self.urls: list = legacy.get('entities', {}).get('url', {}).get('urls', [])
        self.pinned_tweet_ids: list[str] = legacy.get('pinned_tweet_ids_str', [])
        self.is_blue_verified: bool = data.get('is_blue_verified', False)
        self.verified: bool = legacy.get('verified', False)
        self.possibly_sensitive: bool = legacy.get('possibly_sensitive', False)
        self.can_dm: bool = legacy.get('can_dm', False)
        self.can_media_tag: bool = legacy.get('can_media_tag', False)
        self.want_retweets: bool = legacy.get('want_retweets', False)
        self.default_profile: bool = legacy.get('default_profile', False)
        self.default_profile_image: bool = legacy.get('default_profile_image', False)
        self.has_custom_timelines: bool = legacy.get('has_custom_timelines', False)
        self.followers_count: int = legacy.get('followers_count', 0)
        self.fast_followers_count: int = legacy.get('fast_followers_count', 0)
        self.normal_followers_count: int = legacy.get('normal_followers_count', 0)
        self.following_count: int = legacy.get('friends_count', 0)
        self.favourites_count: int = legacy.get('favourites_count', 0)
        self.listed_count: int = legacy.get('listed_count', 0)
        self.media_count = legacy.get('media_count', 0)
        self.statuses_count: int = legacy.get('statuses_count', 0)
        self.is_translator: bool = legacy.get('is_translator', False)
        self.translator_type: str = legacy.get('translator_type', '')
        self.withheld_in_countries: list[str] = legacy.get('withheld_in_countries', [])"""

pattern = re.compile(
    r"^\s*self\.description_urls: list = .*?\n"
    r"^\s*self\.urls: list = .*?\n"
    r"^\s*self\.pinned_tweet_ids: list\[str\] = .*?\n"
    r"^\s*self\.is_blue_verified: bool = .*?\n"
    r"^\s*self\.verified: bool = .*?\n"
    r"^\s*self\.possibly_sensitive: bool = .*?\n"
    r"^\s*self\.can_dm: bool = .*?\n"
    r"^\s*self\.can_media_tag: bool = .*?\n"
    r"^\s*self\.want_retweets: bool = .*?\n"
    r"^\s*self\.default_profile: bool = .*?\n"
    r"^\s*self\.default_profile_image: bool = .*?\n"
    r"^\s*self\.has_custom_timelines: bool = .*?\n"
    r"^\s*self\.followers_count: int = .*?\n"
    r"^\s*self\.fast_followers_count: int = .*?\n"
    r"^\s*self\.normal_followers_count: int = .*?\n"
    r"^\s*self\.following_count: int = .*?\n"
    r"^\s*self\.favourites_count: int = .*?\n"
    r"^\s*self\.listed_count: int = .*?\n"
    r"^\s*self\.media_count = .*?\n"
    r"^\s*self\.statuses_count: int = .*?\n"
    r"^\s*self\.is_translator: bool = .*?\n"
    r"^\s*self\.translator_type: str = .*?\n"
    r"^\s*self\.withheld_in_countries: list\[str\] = .*?$",
    re.MULTILINE | re.DOTALL,
)

new_text, n = pattern.subn(replacement, text, count=1)
if n == 0:
    # already patched or unexpected layout; treat as no-op
    print("NOCHANGE")
    sys.exit(0)

if os.environ.get('DRY_RUN') == '1':
    print("WOULD_PATCH")
    sys.exit(0)

p.write_text(new_text, encoding='utf-8')
print("PATCHED")
PY
}

patch_guest_user_file() {
  local file="$1"
  python3 - "$file" <<'PY'
import os, re, sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')

replacement = """        self.description_urls: list = legacy.get('entities', {}).get('description', {}).get('urls', [])
        self.urls: list = legacy.get('entities', {}).get('url', {}).get('urls', [])
        self.pinned_tweet_ids: list[str] = legacy.get('pinned_tweet_ids_str', [])
        self.is_blue_verified: bool = data.get('is_blue_verified', False)
        self.verified: bool = legacy.get('verified', False)
        self.possibly_sensitive: bool = legacy.get('possibly_sensitive', False)
        self.default_profile: bool = legacy.get('default_profile', False)
        self.default_profile_image: bool = legacy.get('default_profile_image', False)
        self.has_custom_timelines: bool = legacy.get('has_custom_timelines', False)
        self.followers_count: int = legacy.get('followers_count', 0)
        self.fast_followers_count: int = legacy.get('fast_followers_count', 0)
        self.normal_followers_count: int = legacy.get('normal_followers_count', 0)
        self.following_count: int = legacy.get('friends_count', 0)
        self.favourites_count: int = legacy.get('favourites_count', 0)
        self.listed_count: int = legacy.get('listed_count', 0)
        self.media_count = legacy.get('media_count', 0)
        self.statuses_count: int = legacy.get('statuses_count', 0)
        self.is_translator: bool = legacy.get('is_translator', False)
        self.translator_type: str = legacy.get('translator_type', '')
        self.withheld_in_countries: list[str] = legacy.get('withheld_in_countries', [])"""

pattern = re.compile(
    r"^\s*self\.description_urls: list = .*?\n"
    r"^\s*self\.urls: list = .*?\n"
    r"^\s*self\.pinned_tweet_ids: list\[str\] = .*?\n"
    r"^\s*self\.is_blue_verified: bool = .*?\n"
    r"^\s*self\.verified: bool = .*?\n"
    r"^\s*self\.possibly_sensitive: bool = .*?\n"
    r"^\s*self\.default_profile: bool = .*?\n"
    r"^\s*self\.default_profile_image: bool = .*?\n"
    r"^\s*self\.has_custom_timelines: bool = .*?\n"
    r"^\s*self\.followers_count: int = .*?\n"
    r"^\s*self\.fast_followers_count: int = .*?\n"
    r"^\s*self\.normal_followers_count: int = .*?\n"
    r"^\s*self\.following_count: int = .*?\n"
    r"^\s*self\.favourites_count: int = .*?\n"
    r"^\s*self\.listed_count: int = .*?\n"
    r"^\s*self\.media_count = .*?\n"
    r"^\s*self\.statuses_count: int = .*?\n"
    r"^\s*self\.is_translator: bool = .*?\n"
    r"^\s*self\.translator_type: str = .*?\n"
    r"^\s*self\.withheld_in_countries: list\[str\] = .*?$",
    re.MULTILINE | re.DOTALL,
)

new_text, n = pattern.subn(replacement, text, count=1)
if n == 0:
    print("NOCHANGE")
    sys.exit(0)

if os.environ.get('DRY_RUN') == '1':
    print("WOULD_PATCH")
    sys.exit(0)

p.write_text(new_text, encoding='utf-8')
print("PATCHED")
PY
}

patched_user=0
patched_guest=0
copied_tx=0
would_user=0
would_guest=0
would_tx=0

for f in "${USER_FILES[@]}"; do
  if [[ $DRY_RUN -eq 1 ]]; then
    out="$(DRY_RUN=1 patch_user_file "$f")"
  else
    cp -a "$f" "${f}.bak_${TS}"
    out="$(patch_user_file "$f")"
  fi

  if [[ "$out" == "PATCHED" ]]; then
    patched_user=$((patched_user + 1))
    echo "[OK] patched user.py: $f"
  elif [[ "$out" == "WOULD_PATCH" ]]; then
    would_user=$((would_user + 1))
    echo "[DRY] would patch user.py: $f"
  else
    echo "[SKIP] user.py already patched/unmatched: $f"
  fi

  current_step=$((current_step + 1))
  render_progress "$current_step" "$total_steps"
done

for f in "${GUEST_USER_FILES[@]}"; do
  if [[ $DRY_RUN -eq 1 ]]; then
    out="$(DRY_RUN=1 patch_guest_user_file "$f")"
  else
    cp -a "$f" "${f}.bak_${TS}"
    out="$(patch_guest_user_file "$f")"
  fi

  if [[ "$out" == "PATCHED" ]]; then
    patched_guest=$((patched_guest + 1))
    echo "[OK] patched guest/user.py: $f"
  elif [[ "$out" == "WOULD_PATCH" ]]; then
    would_guest=$((would_guest + 1))
    echo "[DRY] would patch guest/user.py: $f"
  else
    echo "[SKIP] guest/user.py already patched/unmatched: $f"
  fi

  current_step=$((current_step + 1))
  render_progress "$current_step" "$total_steps"
done

for f in "${TX_FILES[@]}"; do
  if [[ "$(readlink -f "$f")" == "$(readlink -f "$SOURCE_TX")" ]]; then
    echo "[SKIP] transaction.py source equals target: $f"
    current_step=$((current_step + 1))
    render_progress "$current_step" "$total_steps"
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    would_tx=$((would_tx + 1))
    echo "[DRY] would replace transaction.py: $f"
    current_step=$((current_step + 1))
    render_progress "$current_step" "$total_steps"
    continue
  fi

  cp -a "$f" "${f}.bak_${TS}"
  cp "$SOURCE_TX" "$f"
  copied_tx=$((copied_tx + 1))
  echo "[OK] replaced transaction.py: $f"

  current_step=$((current_step + 1))
  render_progress "$current_step" "$total_steps"
done

if [[ -t 1 ]]; then
  printf '\n'
fi

echo
echo "========== SUMMARY =========="
echo "Mode                 : $([[ $DRY_RUN -eq 1 ]] && echo 'DRY-RUN (no file changes)' || echo 'APPLY')"
echo "Roots                : ${ROOTS[*]}"
echo "Source transaction   : $SOURCE_TX"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Would patch twikit/user   : $would_user"
  echo "Would patch guest/user    : $would_guest"
  echo "Would copy transaction.py : $would_tx"
else
  echo "Patched twikit/user  : $patched_user"
  echo "Patched guest/user   : $patched_guest"
  echo "Copied transaction.py: $copied_tx"
  echo "Backups suffix       : .bak_${TS}"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[DONE] Dry-run complete. No files were modified."
else
  echo "[DONE] Twikit hotfix applied. Restart each bot/service to load changes."
fi
