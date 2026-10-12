#!/usr/bin/env bash
# Gemshard, by menu: checks this machine, sets a shard up from the join code
# the hub's owner gives you, starts it once they have added it, and looks
# after it from then on (status, log, more networks, settings, backup,
# updates). Everything is asked; there are no options to remember.
#
#   bash setup.sh                 in a clone of this repo
#   curl -fsSL https://raw.githubusercontent.com/cban1980/gemshard/main/setup.sh | bash
#                                 clones the repo to ~/gemshard first
set -euo pipefail

REPO_URL=${GEMSHARD_REPO_URL:-https://github.com/cban1980/gemshard}
NAME_RE='^[a-z0-9][a-z0-9_-]{0,31}$'

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok() { echo "  ok: $*"; }
note() { echo "  note: $*"; }
die() { printf '\n%s\n' "$*" >&2; exit 1; }

# Questions come from the terminal, also when this script itself is piped in.
ask() {
  local prompt=$1 default=${2:-} answer
  if [ -n "$default" ]; then prompt="$prompt [$default]"; fi
  read -r -p "$prompt: " answer < /dev/tty || answer=""
  echo "${answer:-$default}"
}
yes_no() { [[ "$(ask "$1 (y/n)" "${2:-n}")" =~ ^[Yy] ]]; }

[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not as root (it asks for sudo where it must)."
[ -r /dev/tty ] || die "This script asks questions, so it needs a terminal."

# --- the repo ------------------------------------------------------------------------------------

here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -z "$here" ] || [ ! -x "$here/bin/gemshard-docker" ]; then
  command -v git >/dev/null || die "git is needed: on Debian/Ubuntu, sudo apt-get install git; then run this again."
  dir=${GEMSHARD_DIR:-$HOME/gemshard}
  if [ -d "$dir/.git" ]; then
    say "Using the copy in $dir"
    git -C "$dir" pull --ff-only --quiet || note "couldn't update $dir; using it as it is"
  else
    say "Getting Gemshard into $dir"
    git clone --quiet "$REPO_URL" "$dir"
  fi
  exec bash "$dir/setup.sh" < /dev/tty
fi
cd "$here"
GD=bin/gemshard-docker

# --- this machine ----------------------------------------------------------------------------------

check_machine() {
  say "Checking this machine"
  command -v git >/dev/null && ok "git" || die "git is needed: on Debian/Ubuntu, sudo apt-get install git"

  if ! command -v docker >/dev/null; then
    if command -v apt-get >/dev/null && yes_no "Docker isn't installed. Install it now (docker.io; asks for sudo)?" y; then
      sudo apt-get update -qq && sudo apt-get install -y -qq docker.io
    else
      die "Docker is needed. Install it (https://docs.docker.com/engine/install/), then run this again."
    fi
  fi
  ok "Docker is installed"

  if ! docker info >/dev/null 2>&1; then
    if command -v systemctl >/dev/null && ! systemctl is-active --quiet docker; then
      yes_no "The Docker service isn't running. Start it now, and at every boot (asks for sudo)?" y &&
        sudo systemctl enable --now docker
    fi
    if ! docker info >/dev/null 2>&1; then
      if ! id -nG | tr ' ' '\n' | grep -qx docker; then
        if yes_no "Your user isn't in the docker group, so it can't use Docker. Add it now (asks for sudo)?" y; then
          sudo usermod -aG docker "$USER"
          die "Added. Log out and back in (or run: newgrp docker), then run this again: bash $here/setup.sh"
        fi
        die "Docker needs your user in the docker group: sudo usermod -aG docker $USER, then log in again."
      fi
      die "Can't reach Docker. Is its service running? sudo systemctl start docker"
    fi
  fi
  ok "Docker works for $USER"

  if command -v systemctl >/dev/null; then
    if systemctl is-enabled --quiet docker 2>/dev/null; then
      ok "Docker starts at boot (and the shards with it)"
    elif yes_no "Docker doesn't start at boot, so the shards wouldn't either. Turn that on (asks for sudo)?" y; then
      sudo systemctl enable docker >/dev/null 2>&1 && ok "Docker starts at boot" || note "couldn't turn that on"
    fi
  fi

  if command -v timedatectl >/dev/null; then
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
      ok "the clock is right"
    else
      note "the clock may be off; the link refuses clocks more than 5 minutes wrong. To fix: sudo timedatectl set-ntp true"
    fi
  fi

  if ! docker image inspect gemshard:latest >/dev/null 2>&1; then
    say "Building the shard's Docker image (the first time takes a minute or two)"
    $GD build >/dev/null 2>&1 || $GD build
    ok "image built"
  fi
}

# --- shards ----------------------------------------------------------------------------------------

shard_names() { $GD list 2>/dev/null | awk '$0 !~ /^No shards/ {print $1}'; }

# Picks a shard: the only one, or one from a list. Empty if there are none.
pick_shard() {
  local names count i choice
  mapfile -t names < <(shard_names)
  count=${#names[@]}
  if [ "$count" -eq 0 ]; then
    echo "  No shards here yet." >&2
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    echo "${names[0]}"
    return 0
  fi
  for i in "${!names[@]}"; do echo "    $((i + 1))) ${names[$i]}" >&2; done
  while true; do
    choice=$(ask "  Which shard? (1-$count)")
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
      echo "${names[$((choice - 1))]}"
      return 0
    fi
  done
}

# Polls status until every network is linked to its hub, or gives up.
wait_linked() {
  local name=$1 out="" deadline=$((SECONDS + 240))
  printf '  waiting for it to get on IRC and link to its hub'
  while [ $SECONDS -lt $deadline ]; do
    out=$($GD status "$name" 2>/dev/null || true)
    if grep -q 'linked to the hub' <<< "$out" && ! grep -q 'not linked\|not on IRC' <<< "$out"; then
      printf '\n%s\n' "$out"
      return 0
    fi
    printf '.'
    sleep 5
  done
  printf '\n%s\n' "$out"
  return 1
}

start_and_wait() {
  local name=$1
  say "Starting $name"
  if $GD status "$name" 2>/dev/null | grep -q 'not running'; then
    $GD start "$name" || return 0
  else
    $GD restart "$name" || return 0
  fi
  if wait_linked "$name"; then
    say "$name is up and linked."
    echo "  It runs by itself from now on, and starts again after a reboot."
    echo "  Run bash setup.sh again any time to look after it."
  else
    cat <<EOF

  Not linked yet. Usually one of these:
  - the hub's owner hasn't added your shard yet: it keeps trying by itself, so
    there's nothing more to do (see how it's doing with "status" later);
  - "not on IRC": the server or port is wrong, or this machine can't reach it
    (change it with "settings");
  - the clock is more than 5 minutes off.
  The last lines of its log:
EOF
    $GD logs "$name" -n 8 2>&1 | sed 's/^/    /'
  fi
}

# After setup or add-network: the SHARD ADD line goes to the hub's owner.
send_line_then_start() {
  local name=$1
  cat <<EOF

  Send the line above to the hub's owner (by IRC, mail, chat; it isn't
  secret). They run it on IRC, and that lets your shard link.
EOF
  if [ "$(ask "Press Enter once they have, or type later to stop here")" = later ]; then
    echo "  Once they have, run bash setup.sh again and choose \"start\"."
  else
    start_and_wait "$name"
  fi
}

new_shard() {
  local default=${USER,,} name
  default=${default//[^a-z0-9_-]/}
  [[ "$default" =~ $NAME_RE ]] || default=shard
  say "Setting up a new shard"
  cat <<EOF
  Have these from the hub's owner at hand: the join code (from SHARD INFO on
  their hub), which IRC server to use, and a nick for the shard.

EOF
  while true; do
    name=$(ask "A name for the shard (a-z, 0-9, _ and -; agree on it with the hub's owner)" "$default")
    if ! [[ "$name" =~ $NAME_RE ]]; then
      echo "  1-32 of a-z, 0-9, _ and -, please."
    elif [ -e "$GEMSHARD_HOME/$name" ]; then
      echo "  There is a shard called $name already."
    else
      break
    fi
  done
  $GD setup "$name" < /dev/tty || return 0
  send_line_then_start "$name"
}

add_network() {
  local name
  name=$(pick_shard) || return 0
  say "Adding a network to $name"
  $GD add-network "$name" < /dev/tty || return 0
  send_line_then_start "$name"
}

show_log() {
  local name
  name=$(pick_shard) || return 0
  $GD logs "$name" -n 40 2>&1 || true
}

change_settings() {
  local name
  name=$(pick_shard) || return 0
  echo "  Opens $name's config.yml in ${EDITOR:-vi} (each network: the hub's details and irc: server, port, tls, nick)."
  if $GD edit "$name" < /dev/tty && yes_no "Restart $name with the new settings now?" y; then
    start_and_wait "$name"
  fi
}

stop_shard() {
  local name
  name=$(pick_shard) || return 0
  yes_no "Stop $name? It leaves IRC until you start it again." n && $GD stop "$name"
}

backup_shard() {
  local name file
  name=$(pick_shard) || return 0
  file=$HOME/gemshard-$name-$(date +%Y%m%d).tar.gz
  $GD backup "$name" "$file"
  echo "  Keep it somewhere private: it holds the shard's key. To move the shard to"
  echo "  another machine, copy it there and choose \"restore\" in its setup.sh."
}

restore_shard() {
  local file
  file=$(ask "Backup file to restore (the full path)")
  [ -f "$file" ] || { echo "  No such file."; return 0; }
  $GD restore "$file" && echo "  Choose \"start\" to run it. Stop the shard on the old machine first."
}

remove_shard() {
  local name
  name=$(pick_shard) || return 0
  echo "  This stops $name and deletes its key for good. Ask the hub's owner to run"
  echo "  SHARD DEL $name too."
  [ "$(ask "Type the shard's name to remove it")" = "$name" ] && $GD remove "$name" --yes || echo "  Left as it is."
}

update_all() {
  say "Getting the newest Gemshard (running shards are restarted)"
  $GD update
}

# --- the menu --------------------------------------------------------------------------------------

export GEMSHARD_HOME=${GEMSHARD_HOME:-$here/shards}
export GEMSHARD_MENU=1   # gemshard-docker leaves out hints about its own commands
check_machine

if [ -z "$(shard_names)" ]; then
  new_shard
fi

while true; do
  say "Gemshard"
  $GD status 2>/dev/null | sed 's/^/  /' || true
  cat <<EOF

    1) status       how the shards are doing (again)
    2) start        start or restart a shard, and check it links
    3) networks     add a network (with its hub) to a shard
    4) log          a shard's latest log lines
    5) settings     change a shard's server, nick, ...
    6) backup       save a shard's key and config to a file
    7) update       get the newest Gemshard
    8) new          set up another shard
    9) restore      bring back a shard from a backup
   10) stop         stop a shard
   11) remove       delete a shard
    q) quit
EOF
  case "$(ask "Choose")" in
    1|status) ;;
    2|start) name=$(pick_shard) && start_and_wait "$name" || true ;;
    3|networks) add_network || true ;;
    4|log) show_log || true ;;
    5|settings) change_settings || true ;;
    6|backup) backup_shard || true ;;
    7|update) update_all || true ;;
    8|new) new_shard || true ;;
    9|restore) restore_shard || true ;;
    10|stop) stop_shard || true ;;
    11|remove) remove_shard || true ;;
    q|Q|quit|"") exit 0 ;;
    *) echo "  Choose a number (or q)." ;;
  esac
done
