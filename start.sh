#!/bin/bash

# Postfix Admin Utility v1.0
# Interactive administration menu for Postfix and SpamAssassin
# Works in simulation mode or real mode.

# Base directories
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$BASE_DIR/log"
SPAM_EML_DIR="$BASE_DIR/spam_emls"
BACKUP_DIR="$BASE_DIR/backup"
RULES_DIR="$BASE_DIR/rules_generated"
TMP_DIR="$BASE_DIR/tmp"

# ensure directories exist
mkdir -p "$LOG_DIR" "$SPAM_EML_DIR" "$BACKUP_DIR" "$RULES_DIR" "$TMP_DIR"

# Colors (can be disabled by NO_COLOR env)
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  RED='\e[31m'
  GREEN='\e[32m'
  YELLOW='\e[33m'
  BLUE='\e[34m'
  RESET='\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET="";
fi

# Logging
LOG_FILE="$LOG_DIR/start_$(date +%Y%m%d_%H%M).log"
MODE="" # SIMULATION or REAL

log() {
  local message="$1"
  echo "$(date '+%F %T') [$MODE] $message" | tee -a "$LOG_FILE"
}

run_cmd() {
  local cmd="$1"
  if [ "$MODE" = "SIMULATION" ]; then
    echo -e "${YELLOW}[SIMULATION]${RESET} $cmd"
    log "SIMULATION: $cmd"
  else
    eval "$cmd" && log "OK: $cmd" || log "[ERROR] $cmd"
  fi
}

pause() {
  read -rp "Press Enter to continue..." dummy
}

##########################
# Queue management
##########################

show_queue() {
  echo -e "${BLUE}Postfix queue status:${RESET}"
  postqueue -p
}

get_ids_by_recipient() {
  local pattern="$1"
  postqueue -p | grep -B1 "$pattern" | awk '/^[A-F0-9]{10,}/ {print $1}'
}

clean_queue_pattern() {
  local pattern="$1" desc="$2"
  local ids=$(get_ids_by_recipient "$pattern")
  for id in $ids; do
    local sender=$(postcat -q "$id" 2>/dev/null | awk '/^sender:/ {print $2}')
    local rcpt=$(postcat -q "$id" 2>/dev/null | awk '/^recipient:/ {print $2}')
    run_cmd "postsuper -d $id"
    log "Removed $id From:$sender To:$rcpt"
  done
  [ -z "$ids" ] && echo "No matching messages."
}

clean_ru() { clean_queue_pattern '\\.ru>' '.ru recipients'; }
clean_azart() { clean_queue_pattern '@azart\.in>' '@azart.in recipients'; }
clean_gmail_overquota() {
  local ids=$(postqueue -p | grep -B1 'gmail.com' | grep -B1 'quota' | awk '/^[A-F0-9]{10,}/ {print $1}')
  for id in $ids; do run_cmd "postsuper -d $id"; done
  [ -z "$ids" ] && echo "No matching messages." && log "No gmail overquota messages"
}

clean_deferred_days() {
  local days=${1:-5}
  find /var/spool/postfix/deferred -type f -mtime +$days -printf '%f\n' 2>/dev/null | while read -r id; do
    run_cmd "postsuper -d $id"
  done
}

clean_by_id() {
  read -rp "Enter QUEUE_ID: " id
  run_cmd "postsuper -d $id"
}

clean_by_daterange() {
  echo "Enter start date (YYYY-MM-DD):"
  read start
  echo "Enter end date (YYYY-MM-DD):"
  read end
  echo "Not fully implemented: requires parsing queue file timestamps";
}

view_message() {
  read -rp "Enter QUEUE_ID: " id
  postcat -q "$id" | sed -n '1,40p'
}

queue_menu() {
  while true; do
    clear
    echo "Queue Menu (Mode: $MODE)"
    cat <<EOM
1) Show queue
2) Clean .ru recipients
3) Clean @azart.in
4) Clean Gmail overquota
5) Clean deferred older than N days
6) Clean by QUEUE_ID
7) Clean by date range
8) View message by QUEUE_ID
0) Back
EOM
    read -rp "Choose: " choice
    case $choice in
      1) show_queue; pause;;
      2) clean_ru; pause;;
      3) clean_azart; pause;;
      4) clean_gmail_overquota; pause;;
      5) read -rp "Days (default 5): " d; clean_deferred_days "${d:-5}"; pause;;
      6) clean_by_id; pause;;
      7) clean_by_daterange; pause;;
      8) view_message; pause;;
      0) break;;
      *) echo "Invalid choice"; pause;;
    esac
  done
}

##########################
# SpamAssassin functions
##########################

add_signature() {
  read -rp "Rule type (body/header/uri): " type
  read -rp "Rule name: " name
  read -rp "Pattern (regex): " pattern
  read -rp "Score: " score
  local rule=""
  case "$type" in
    body) rule="body $name /$pattern/";;
    header) read -rp "Header name: " header; rule="header $name $header =~ /$pattern/";;
    uri) rule="uri $name /$pattern/";;
    *) echo "Unknown type"; return;;
  esac
  echo "$rule" >> "$RULES_DIR/generated_manual_$(date +%Y%m%d_%H%M).cf"
  echo "score $name $score" >> "$RULES_DIR/generated_manual_$(date +%Y%m%d_%H%M).cf"
  log "Added manual rule $name"
}

next_payment_rule() {
  local last=$(ls "$RULES_DIR" 2>/dev/null | grep PAYMENT_SPAM | tail -n1 | sed 's/.*_\([0-9][0-9]\)\.cf/\1/' )
  last=${last:-00}
  printf '%02d' $((10#$last + 1))
}

analyze_eml() {
  local timestamp=$(date +%Y%m%d_%H%M)
  local outfile="$RULES_DIR/generated_${timestamp}.cf"
  local num=$(next_payment_rule)
  for file in "$SPAM_EML_DIR"/*.eml; do
    [ -e "$file" ] || continue
    grep -Eo 'https?://[^ ]+' "$file" | sort -u >> "$TMP_DIR/urls.tmp"
    grep -Eo '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,6}\b' "$file" | sort -u >> "$TMP_DIR/emails.tmp"
    grep -Eo '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' "$file" | sort -u >> "$TMP_DIR/ips.tmp"
  done
  echo "; Generated rules" > "$outfile"
  if [ -s "$TMP_DIR/urls.tmp" ]; then
    while read -r url; do
      echo "uri PAYMENT_SPAM_$num /$url/" >> "$outfile"
      echo "describe PAYMENT_SPAM_$num Auto-generated rule" >> "$outfile"
      echo "score PAYMENT_SPAM_$num 5.0" >> "$outfile"
      num=$(printf '%02d' $((10#$num + 1)))
    done < "$TMP_DIR/urls.tmp"
  fi
  log "Generated rules to $outfile"
  rm -f "$TMP_DIR"/*.tmp
  echo "Rules saved to $outfile"
  echo "Copy rules to /etc/mail/spamassassin/local.cf and restart service"
}

rollback_localcf() {
  local latest=$(ls -t "$BACKUP_DIR" 2>/dev/null | head -n1)
  [ -z "$latest" ] && { echo "No backups"; return; }
  run_cmd "cp /etc/mail/spamassassin/local.cf $BACKUP_DIR/local.cf_$(date +%Y%m%d_%H%M)"
  run_cmd "cp $BACKUP_DIR/$latest /etc/mail/spamassassin/local.cf"
  log "Restored local.cf from $latest"
}

test_rules() {
  read -rp "Enter .eml file: " file
  if [ -f "$file" ]; then
    spamassassin -D "$file" 2>&1 | less
  else
    echo "File not found"
  fi
}

spam_menu() {
  while true; do
    clear
    echo "SpamAssassin Menu (Mode: $MODE)"
    cat <<EOM
1) Add signature manually
2) Analyze .eml in spam_emls/
3) Rollback local.cf from backup
4) Test rules on .eml
0) Back
EOM
    read -rp "Choose: " choice
    case $choice in
      1) add_signature; pause;;
      2) analyze_eml; pause;;
      3) rollback_localcf; pause;;
      4) test_rules; pause;;
      0) break;;
      *) echo "Invalid"; pause;;
    esac
  done
}

##########################
# Log functions
##########################

log_menu() {
  while true; do
    clear
    echo "Postfix Logs Menu"
    cat <<EOM
1) Last 100 errors
2) Search blocked/bounced
3) Search .ru/.cn/.site attempts
4) Search by phrase
5) TOP-10 SpamAssassin rules
0) Back
EOM
    read -rp "Choose: " choice
    case $choice in
      1) tail -n 100 /var/log/maillog | grep -i 'error'; pause;;
      2) grep -iE 'blocked|bounced' /var/log/maillog; pause;;
      3) grep -iE '\\.ru|\\.cn|\\.site' /var/log/maillog; pause;;
      4) read -rp "Phrase: " p; grep -i "$p" /var/log/maillog; pause;;
      5) grep 'spamd' /var/log/maillog | awk -F' ' '{for(i=1;i<=NF;i++) if($i~/^[A-Z_]+$/) c[$i]++} END{for(i in c) printf "%s %s\n",c[i],i}' | sort -nr | head -n10; pause;;
      0) break;;
      *) echo "Invalid"; pause;;
    esac
  done
}

##########################
# Diagnostics
##########################

diag_menu() {
  while true; do
    clear
    echo "Diagnostics Menu"
    cat <<EOM
1) Queue size
2) Count deferred
3) Last errors in maillog
4) local.cf last modification
5) DNSBL/SPF check
0) Back
EOM
    read -rp "Choose: " choice
    case $choice in
      1) postqueue -p | tail -n1; pause;;
      2) postqueue -p | grep -c "deferred"; pause;;
      3) tail -n 20 /var/log/maillog; pause;;
      4) stat -c '%y' /etc/mail/spamassassin/local.cf 2>/dev/null; pause;;
      5) read -rp "Domain or IP: " host; dig "$host" txt +short; pause;;
      0) break;;
      *) echo "Invalid"; pause;;
    esac
  done
}

##########################
# Main menu
##########################

main_menu() {
  while true; do
    clear
    echo "Main Menu (Mode: $MODE)"
    cat <<EOM
1) Mail queue
2) SpamAssassin
3) Postfix logs
4) Diagnostics and stats
0) Exit
EOM
    read -rp "Choose: " choice
    case $choice in
      1) queue_menu;;
      2) spam_menu;;
      3) log_menu;;
      4) diag_menu;;
      0) exit 0;;
      *) echo "Invalid choice"; pause;;
    esac
  done
}

##########################
# Mode selection
##########################

select_mode() {
  while true; do
    clear
    cat <<EOM
====================================
   Postfix Admin Utility v1.0
====================================
Select mode:
1) Simulation
2) Real
0) Exit
EOM
    read -rp "Choose: " m
    case $m in
      1) MODE="SIMULATION"; log "Started in simulation mode"; main_menu;;
      2) MODE="REAL"; log "Started in real mode"; main_menu;;
      0) exit 0;;
      *) echo "Invalid"; sleep 1;;
    esac
  done
}

select_mode

