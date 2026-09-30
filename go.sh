#!/usr/bin/env bash
# The one command for the platform on this server. Run it any time:
#
#     bash go.sh
#
# It works out what is needed: a setup in progress -> shows its progress;
# nothing installed -> full install; installed -> applies any newer export
# (code and configuration only, never the databases) and re-checks everything.
# It runs as a background service, so closing PuTTY does not stop it.
#
# The FTP password is asked once and kept root-only on this server.
# MODE=update|rebuild|check forces that step instead of the automatic choice.
set -uo pipefail
# Files come over HTTPS from the source server (FTP was closed on this network).
BASE="${BASE:-https://fhlcinadayuuat.blob.core.windows.net/fortis-uat-transfer}"
# Set when the files come from Azure storage: the read-only link (SAS) for every
# file. Then there is no password; the settings file is encrypted, and the key
# asked for below opens it.
QS="${QS:-}"
# Bootstrap: where the Azure link is published encrypted with the transfer key (a
# short public GitHub address UAT can type). Read afresh every run, so a renewed
# link needs no new go.sh.
BOOT="${BOOT:-https://github.com/shunyaadmin/u/raw/main/link}"
DIR="${DIR:-/var/lib/fortis-transfer}"; BIN=$DIR/bin; PASSFILE=$BIN/.ftp-pass
LOG="${LOG:-/var/log/fortis-go.log}"; UNIT="${UNIT:-fortis-go}"; RESULT=$DIR/RESULT.txt

# curl as root, password on stdin (sudo does not pass other file descriptors on).
# Prints the HTTP status: 200 fine, 401 wrong password, 000 no connection.
ftp_get() {
  if [ -n "$QS" ]; then sudo curl -sS -m 600 --retry 3 -o "$3" -w '%{http_code}' "$BASE/$2?$QS" 2>/dev/null
  else printf 'user = "ftpmigrate:%s"\n' "$1" | sudo curl -sS -m 60 --retry 3 -K - -o "$3" -w '%{http_code}' "$BASE/$2" 2>/dev/null; fi
}
# Azure mode: the key is right if it opens key-check.enc.
key_ok() {
  [ "$(ftp_get x key-check.enc "$BIN/key-check.enc")" = 200 ] || return 2
  printf '%s\n' "$1" | sudo openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass stdin -in "$BIN/key-check.enc" 2>/dev/null | grep -q fortis-ok
}

show_result() {
  echo; echo "=================== COPY FROM HERE ==================="
  sudo cat "$RESULT"
  echo "=================== COPY TO HERE ====================="
  sudo grep -q '^STATUS: OK' "$RESULT" && printf '\n\033[1;32mEverything is up.\033[0m\n' \
    || printf '\n\033[1;31mNot finished.\033[0m Copy the block above and send it to Claude, then run  bash go.sh  again after the fix.\n'
}

# Networks that inspect HTTPS (as Fortis does) re-sign every site with their own
# certificate, which Ubuntu does not know: curl then fails with error 60. Show who
# signed what this server receives and, only if the person agrees, add that
# certificate to the system store -- this fixes curl, git and apt for good.
trust_network_cert() {
  local host=${BASE#https://}; host=${host%%/*}
  sudo curl -sS -m 30 -o /dev/null "https://$host/" 2>/dev/null; [ $? = 60 ] || return 0
  local chain; chain=$(timeout 30 openssl s_client -connect "$host:443" -servername "$host" -showcerts </dev/null 2>/dev/null)
  local top; top=$(printf '%s\n' "$chain" | awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{last=c} END{printf "%s", last}')
  [ -n "$top" ] || { echo "Could not read $host's certificate."; exit 1; }
  echo "HTTPS to $host is not trusted on this server. The certificate received:"
  printf '%s' "$chain" | openssl x509 -noout -subject -issuer 2>/dev/null | sed 's/^/    site    /'
  printf '%b' "$top" | openssl x509 -noout -subject -issuer 2>/dev/null | sed 's/^/    signer  /'
  if printf '%s' "$chain" | openssl x509 -noout -issuer 2>/dev/null | grep -q "Let's Encrypt"; then
    echo "That is the real certificate, so this server's CA list is out of date. Updating it..."
    sudo apt-get install -y -qq ca-certificates >/dev/null 2>&1; sudo update-ca-certificates >/dev/null 2>&1
  else
    echo "The site's real certificate is from Let's Encrypt, so this one comes from the network's"
    echo "HTTPS inspection. If the signer above is your company's (Fortis, Zscaler, Palo Alto, Fortinet...),"
    read -rp "trust it on this server? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || exit 1
    printf '%b' "$top" | sudo tee /usr/local/share/ca-certificates/network-inspection.crt >/dev/null
    sudo update-ca-certificates >/dev/null 2>&1
  fi
  sudo curl -sS -m 30 -o /dev/null "https://$host/" 2>/dev/null; [ $? = 60 ] && { echo "Still not trusted -- send this screen to Claude."; exit 1; }
  echo "Trusted. Continuing."
}

sudo true || exit 1
trust_network_cert

# The Azure link, opened with the transfer key (asked once, kept root-only).
open_link() {
  [ -n "$1" ] || return 1
  sudo curl -fsSL -m 60 -o "$BIN/link.b64" "$BOOT" 2>/dev/null || { echo "Cannot fetch $BOOT (network, or certificate: try  curl -I $BOOT)" >&2; return 1; }
  sudo sh -c "base64 -d '$BIN/link.b64' > '$BIN/link.enc'" 2>/dev/null || return 1
  printf '%s\n' "$1" | sudo openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass stdin -in "$BIN/link.enc" 2>/dev/null
}
if [ -n "$BOOT" ] && [ -z "$QS" ] && ! systemctl is-active --quiet "$UNIT"; then
  sudo mkdir -p "$BIN" && sudo chmod 700 "$BIN"
  P=$(sudo cat "$PASSFILE" 2>/dev/null || true)
  QS=$(open_link "$P")
  case "$QS" in sv=*) ;; *)
    read -rsp "Transfer key (sent to you separately): " P; echo
    QS=$(open_link "$P")
    case "$QS" in sv=*) ;; *) echo "That key does not open the link. Check it and run  bash go.sh  again."; exit 1;; esac
    printf '%s' "$P" | sudo tee "$PASSFILE" >/dev/null; sudo chmod 600 "$PASSFILE";;
  esac
fi
if systemctl is-active --quiet "$UNIT"; then
  echo "Setup is already running -- showing its progress. (Ctrl+C stops watching only; the setup continues.)"
else
  sudo mkdir -p "$BIN" && sudo chmod 700 "$BIN"
  P=$(sudo cat "$PASSFILE" 2>/dev/null || true)
  if [ -n "$QS" ]; then
    code=$(ftp_get x run.sh /dev/null)
    [ "$code" = 403 ] && { echo "The download link has expired. Ask for a new go.sh."; exit 1; }
    [ "$code" = 200 ] || { echo "Cannot reach ${BASE%/*} (HTTP $code). Check this server's internet access."; exit 1; }
    if ! { [ -n "$P" ] && key_ok "$P"; }; then
      read -rsp "Transfer key (sent to you separately): " P; echo
      key_ok "$P" || { echo "That key does not open the files. Check it and run  bash go.sh  again."; exit 1; }
      printf '%s' "$P" | sudo tee "$PASSFILE" >/dev/null; sudo chmod 600 "$PASSFILE"
    fi
  fi
  code=$([ -n "$P" ] && ftp_get "$P" run.sh /dev/null || echo 401)
  [ "$code" = 000 ] && { echo "Cannot reach ${BASE%/*} (HTTPS). Check this server's internet access."; exit 1; }
  if [ "$code" != 200 ]; then
    [ -n "$P" ] && echo "The saved password was not accepted (HTTP $code)."
    read -rsp "Transfer password (the FTP password): " P; echo
    code=$(ftp_get "$P" run.sh /dev/null)
    [ "$code" = 200 ] || { echo "Not accepted (HTTP $code). Check the password."; exit 1; }
    printf '%s' "$P" | sudo tee "$PASSFILE" >/dev/null; sudo chmod 600 "$PASSFILE"
  fi
  [ "$(ftp_get "$P" run.sh "$BIN/run.sh")" = 200 ] || { echo "Could not fetch the setup logic."; exit 1; }
  printf 'DOMAIN=%q\nBASE=%q\nQS=%q\nDIR=%q\nMODE=%q\nSTUB=%q\nCODE=%q\n' "${NEW_DOMAIN:-uat.adayu.com}" "$BASE" "$QS" "$DIR" \
    "${MODE:-}" "${STUB:-}" "${CODE:-/opt/fortis}" | sudo tee "$BIN/settings" >/dev/null
  sudo truncate -s0 "$LOG" 2>/dev/null || true
  sudo systemd-run --unit="$UNIT" --collect --quiet -p StandardOutput=append:"$LOG" -p StandardError=append:"$LOG" \
       bash "$BIN/run.sh" || { echo "Could not start the setup service."; exit 1; }
  echo "Started in the background. Progress below; closing this window does not stop it."
fi

sleep 1
PID=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null)
[ -n "$PID" ] && [ "$PID" != 0 ] && sudo tail -n 40 -F "$LOG" --pid="$PID" 2>/dev/null
sudo test -f "$RESULT" && show_result || echo "No result yet -- run  bash go.sh  again to keep watching."
