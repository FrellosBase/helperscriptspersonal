#!/usr/bin/env bash

while true; do
    read -p "Dit zal een nieuwe Home Assistant OS VM maken. Doorgaan (j/n)?" yn
    case $yn in
        [Jj]* ) break;;
        [Nn]* ) exit;;
        * ) echo "Antwoord alstublieft met ja of nee.";;
    esac
done
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s expand_aliases
alias stop='EXIT=$? LINE=$LINENO stop_error'
CHECKMARK='\033[0;32m\xE2\x9C\x94\033[0m'
trap stop ERR
trap cleanup EXIT
function stop_error() {
  trap - ERR
  local STANDAARD='Onbekende fout opgetreden.'
  local REDEN="\e[97m${1:-$STANDAARD}\e[39m"
  local VLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  bericht "$VLAG $REDEN"
  [ ! -z ${VMID-} ] && cleanup_vmid
  exit $EXIT
}
function waarschuwing() {
  local REDEN="\e[97m$1\e[39m"
  local VLAG="\e[93m[WAARSCHUWING]\e[39m"
  bericht "$VLAG $REDEN"
}
function info() {
  local REDEN="$1"
  local VLAG="\e[36m[INFO]\e[39m"
  bericht "$VLAG $REDEN"
}
function bericht() {
  local TEKST="$1"
  echo -e "$TEKST"
}
function cleanup_vmid() {
  if $(qm status $VMID &>/dev/null); then
    if [ "$(qm status $VMID | awk '{print $2}')" == "running" ]; then
      qm stop $VMID
    fi
    qm destroy $VMID
  fi
}
function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null
while read -r regel; do
  TAG=$(echo $regel | awk '{print $1}')
  TYPE=$(echo $regel | awk '{printf "%-10s", $2}')
  FREE=$(echo $regel | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=( "$TAG" "$ITEM" "UIT" )
done < <(pvesm status -content images | awk 'NR>1')
if [ $((${#STORAGE_MENU[@]}/3)) -eq 0 ]; then
  waarschuwing "'Disk image' moet geselecteerd worden voor ten minste één opslaglocatie."
  stop "Kan geen geldige opslaglocatie detecteren."
elif [ $((${#STORAGE_MENU[@]}/3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --title "Opslagpools" --radiolist \
    "Welke opslagpool wilt u gebruiken voor de container?\n\n" \
    16 $(($MSG_MAX_LENGTH + 23)) 6 \
    "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit
  done
fi
info "Gebruik '$STORAGE' als opslaglocatie."
VMID=$(pvesh get /cluster/nextid)
info "VM ID is $VMID."
echo -e "\e[1;33m URL voor nieuwste Home Assistant disk image ophalen... \e[0m"
RELEASE_TYPE=qcow2
URL=$(cat<<EOF | python3
import requests
url = "https://api.github.com/repos/home-assistant/operating-system/releases"
r = requests.get(url).json()
if "message" in r:
    exit()
for release in r:
    if release["prerelease"]:
        continue
    for asset in release["assets"]:
        if asset["name"].find("$RELEASE_TYPE") != -1:
            image_url = asset["browser_download_url"]
            print(image_url)
            exit()
EOF
)
if [ -z "$URL" ]; then
  stop "Github heeft een fout geretourneerd. Er is mogelijk een tariefbeperking van toepassing op uw
