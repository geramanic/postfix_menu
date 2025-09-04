#!/bin/bash
# Postfix Admin Utility v1.3.1 (CentOS 7, Postfix 2.10.1, SpamAssassin 3.4.0)
# Автор: geramanic & co-pilot
# Режимы: Симуляция / Реальна робота
# Язык: UA (default) / EN

##############################################################################
# БАЗОВЫЕ НАСТРОЙКИ
##############################################################################
set -uo pipefail
umask 077

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$BASE_DIR/log"
SPAM_EML_DIR="$BASE_DIR/spam_emls"
BACKUP_DIR="$BASE_DIR/backup"
RULES_DIR="$BASE_DIR/rules_generated"
TMP_DIR="$BASE_DIR/tmp"
LOCK_FILE="$TMP_DIR/.lock"

POSTFIX_QUEUE_DIR="/var/spool/postfix"
SA_LOCAL_CF="/etc/mail/spamassassin/local.cf"

mkdir -p "$LOG_DIR" "$SPAM_EML_DIR" "$BACKUP_DIR" "$RULES_DIR" "$TMP_DIR"

# Цвета (отключить: NO_COLOR=1)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'; DIM='\e[2m'; RESET='\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; DIM=""; RESET="";
fi

TS() { date +%Y%m%d_%H%M%S; }
LOG_FILE="$LOG_DIR/start_$(date +%Y%m%d_%H%M).log"

# Глобальные флаги
MODE=""           # SIMULATION|REAL
LANG_CHOICE="UA"  # UA|EN
RATE_SLEEP=0.05   # задержка между массовыми операциями
SAFE_MAX=1000     # > этого числа спросим "YES"
WHITELIST_REGEX='@msl\.ua$'  # никогда не трогаем получателей/отправителей, совпавших с этим

##############################################################################
# ЯЗЫК/LOCALE
##############################################################################
_() {
  case "$1|$LANG_CHOICE" in
    "mode_sim|UA") echo "СИМУЛЯЦІЯ";;
    "mode_sim|EN") echo "SIMULATION";;
    "mode_real|UA") echo "РЕАЛ";;
    "mode_real|EN") echo "REAL";;

    "press_enter|UA") echo "Натисніть Enter для продовження...";;
    "press_enter|EN") echo "Press Enter to continue...";;

    "no_matches|UA") echo "Нічого не знайдено.";;
    "no_matches|EN") echo "No matches found.";;

    "invalid_choice|UA") echo "Невірний вибір.";;
    "invalid_choice|EN") echo "Invalid choice.";;

    "preview_header|UA") echo "Попередній перегляд вибірки до дії:";;
    "preview_header|EN") echo "Preview of selection before action:";;

    "confirm|UA") echo "Виконати дію? [y/N]:";;
    "confirm|EN") echo "Proceed? [y/N]:";;

    "confirm_big|UA") echo "Знайдено більше $SAFE_MAX повідомлень. Щоб продовжити, введіть YES:";;
    "confirm_big|EN") echo "More than $SAFE_MAX messages found. To continue, type YES:";;

    "queue_title|UA") echo "Стан черги Postfix:";;
    "queue_title|EN") echo "Postfix queue status:";;

    "enter_queueid|UA") echo "Введіть QUEUE_ID (A-F0-9):";;
    "enter_queueid|EN") echo "Enter QUEUE_ID (A-F0-9):";;

    "enter_days|UA") echo "Скільки днів (за замовчуванням 5):";;
    "enter_days|EN") echo "Days (default 5):";;

    "enter_phrase|UA") echo "Фраза для пошуку:";;
    "enter_phrase|EN") echo "Search phrase:";;

    "show_last_rules|UA") echo "Останній згенерований rules-файл:";;
    "show_last_rules|EN") echo "Last generated rules file:";;

    "backup_made|UA") echo "Створено резервну копію local.cf:";;
    "backup_made|EN") echo "Backup of local.cf created:";;

    "no_backups|UA") echo "Резервні копії відсутні.";;
    "no_backups|EN") echo "No backups available.";;

    "choose_backup|UA") echo "Виберіть файл для відкату (номер):";;
    "choose_backup|EN") echo "Choose backup to restore (number):";;

    "restored|UA") echo "Відновлено local.cf з:";;
    "restored|EN") echo "local.cf restored from:";;

    "lint_ok|UA") echo "Перевірка spamassassin --lint пройдена без критичних помилок.";;
    "lint_ok|EN") echo "spamassassin --lint passed without critical errors.";;

    "lint_fail|UA") echo "ПОМИЛКА lint: перегляньте лог і виправте файл перед застосуванням.";;
    "lint_fail|EN") echo "LINT ERROR: check the log and fix file before applying.";;

    "stats_before|UA") echo "Стан до операції:";;
    "stats_after|UA") echo "Стан після операції:";;
    "stats_before|EN") echo "State before operation:";;
    "stats_after|EN") echo "State after operation:";;

    "headers_title|UA") echo "Ключові заголовки повідомлення:";;
    "headers_title|EN") echo "Key message headers:";;

    "diag_title|UA") echo "Діагностика сервера:";;
    "diag_title|EN") echo "Server diagnostics:";;

    "lang_select|UA") echo "Оберіть мову: 1) Українська (за замовч.)  2) English";;
    "lang_select|EN") echo "Select language: 1) Українська (default)  2) English";;
    * ) echo "$1" ;;
  esac
}

##############################################################################
# ЛОГИ/ВЫВОД/ПРОЧЕЕ
##############################################################################
log()  { echo "$(date '+%F %T') [$MODE] $1" | tee -a "$LOG_FILE"; }
say()  { echo -e "$1" | tee -a "$LOG_FILE"; }
pause(){ read -rp "$(_ press_enter) " _dummy; }

# Безопасный вывод: печатаем stdin и сразу возвращаемся в меню
show_and_pause(){ cat; echo; pause; }

rotate_logs() {
  find "$LOG_DIR" -type f -mtime +365 -delete 2>/dev/null || true
  local count; count=$(find "$LOG_DIR" -type f | wc -l)
  if [ "$count" -gt 500 ]; then
    find "$LOG_DIR" -type f -printf '%T@ %p\n' | sort -n | head -n "$((count-500))" | awk '{print $2}' | xargs -r rm -f
  fi
}

##############################################################################
# ПРЕФЛАЙТ / БЕЗОПАСНОСТЬ
##############################################################################
cleanup() { rm -f "$TMP_DIR"/*.tmp 2>/dev/null || true; }
trap cleanup EXIT INT TERM

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root.${RESET}"
    exit 1
  fi
}

check_binaries() {
  local missing=0
  for b in postqueue postcat postsuper spamassassin grep awk sed tr find stat head tail wc cut sort uniq; do
    command -v "$b" >/dev/null 2>&1 || { echo "Missing binary: $b"; missing=1; }
  done
  command -v journalctl >/dev/null 2>&1 || true
  [ "$missing" -eq 0 ] || exit 1
  [ -d "$POSTFIX_QUEUE_DIR" ] || { echo "No postfix queue dir: $POSTFIX_QUEUE_DIR"; exit 1; }
  [ -f "$SA_LOCAL_CF" ] || { echo "No SpamAssassin local.cf: $SA_LOCAL_CF"; exit 1; }
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "Another instance is running. Lock: $LOCK_FILE"
    exit 1
  fi
  echo "$$ $(date '+%F %T')" 1>&9
}

##############################################################################
# ВСПОМОГАТЕЛЬНЫЕ: ПРЕВЬЮ/ПОДТВЕРЖДЕНИЕ/ЛИМИТ
##############################################################################
queue_stats() {
  local active deferred hold total
  active=$(find "$POSTFIX_QUEUE_DIR/active" -type f 2>/dev/null | wc -l)
  deferred=$(find "$POSTFIX_QUEUE_DIR/deferred" -type f 2>/dev/null | wc -l)
  hold=$(find "$POSTFIX_QUEUE_DIR/hold" -type f 2>/dev/null | wc -l)
  total=$(postqueue -p | tail -n1)
  echo -e "$(_ stats_before) ${DIM}(active:$active deferred:$deferred hold:$hold)${RESET}"
  echo "$total"
}

preview_ids() {
  awk 'NF' | while read -r id; do
    [[ "$id" =~ ^[A-F0-9]+$ ]] || continue
    local H="$(postcat -q "$id" 2>/dev/null | sed -n '1,120p')"
    local FROM="$(echo "$H" | awk -F': ' '/^From:/{print $2; exit}')"
    local TO="$(echo "$H" | awk -F': ' '/^To:/{print $2; exit}')"
    local SUBJ="$(echo "$H" | awk -F': ' '/^Subject:/{print substr($0,index($0,$2)); exit}')"
    printf "%-12s | %s | %s | %s\n" "$id" "${FROM:-?}" "${TO:-?}" "${SUBJ:-?}"
  done
}

confirm_action() {
  local count="$1"
  echo -e "${YELLOW}$(_ preview_header)${RESET}"
  if [ "$count" -gt "$SAFE_MAX" ]; then
    read -rp "$(_ confirm_big) " big
    [ "$big" = "YES" ] || { echo "Canceled."; return 1; }
  else
    read -rp "$(_ confirm) " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Canceled."; return 1; }
  fi
  return 0
}

rate_sleep() { sleep "$RATE_SLEEP"; }

##############################################################################
# ОБЩИЕ УТИЛИТЫ
##############################################################################
cmd() {
  local c="$1"
  if [ "$MODE" = "SIMULATION" ]; then
    echo -e "${YELLOW}[SIMULATION]${RESET} $c"
    log "SIMULATION: $c"
    return 0
  else
    eval "$c"
    local rc=$?
    if [ $rc -eq 0 ]; then log "OK: $c"; else log "[ERROR:$rc] $c"; fi
    return $rc
  fi
}

list_ids_by() {
  local pattern="$1"
  postqueue -p | grep -B1 -E "$pattern" | awk '/^[A-F0-9]{5,}/ {print $1}' | sort -u
}

validate_id() {
  local id="$1"
  [[ "$id" =~ ^[A-F0-9]+$ ]] || return 1
  postqueue -p | awk '/^[A-F0-9]{5,}/{print $1}' | grep -qx "$id"
}

is_whitelisted() {
  local id="$1"
  local hdr="$(postcat -q "$id" 2>/dev/null | sed -n '1,80p')"
  echo "$hdr" | grep -Eqi "$WHITELIST_REGEX"
}

##############################################################################
# МЕНЮ: ОЧЕРЕДЬ
##############################################################################
show_queue() { echo -e "${BLUE}$(_ queue_title)${RESET}"; postqueue -p; }

view_message_headers() {
  read -rp "$(_ enter_queueid) " id
  validate_id "$id" || { echo "Invalid ID."; return; }
  echo -e "${BLUE}$(_ headers_title)${RESET}"
  postcat -q "$id" | awk '
    BEGIN{IGNORECASE=1}
    /^From:/ || /^To:/ || /^Subject:/ || /^Date:/ || /^Message-ID:/ ||
    /^Received:/ || /^Authentication-Results:/ || /^DKIM-/ || /^SPF/ {print}
    NR>120{exit}
  ' | sed -n '1,120p' | show_and_pause
}

remove_by_pattern() {
  local label="$1" pattern="$2"
  echo -e "${BLUE}Filter:${RESET} $label"
  mapfile -t IDS < <(list_ids_by "$pattern")
  local total="${#IDS[@]}"
  [ "$total" -eq 0 ] && { echo "$(_ no_matches)"; pause; return; }

  echo -e "${DIM}IDs matched: $total${RESET}"
  printf "%s\n" "${IDS[@]}" | head -n 25 | preview_ids | sed 's/^/  /'
  [ "$total" -gt 25 ] && echo "  ... ($((total-25)) more)"

  confirm_action "$total" || { pause; return; }

  queue_stats
  local n=0
  for id in "${IDS[@]}"; do
    is_whitelisted "$id" && { echo "SKIP (whitelisted): $id"; continue; }
    cmd "postsuper -d $id" && n=$((n+1))
    rate_sleep
  done
  echo "Removed: $n / matched: $total"
  queue_stats
  pause
}

requeue_by_pattern() {
  local label="$1" pattern="$2"
  mapfile -t IDS < <(list_ids_by "$pattern")
  local total="${#IDS[@]}"
  [ "$total" -eq 0 ] && { echo "$(_ no_matches)"; pause; return; }
  echo -e "${BLUE}Requeue:${RESET} $label  ($total)"
  printf "%s\n" "${IDS[@]}" | head -n 25 | preview_ids | sed 's/^/  /'
  confirm_action "$total" || { pause; return; }
  local n=0
  for id in "${IDS[@]}"; do
    cmd "postsuper -r $id" && n=$((n+1))
    rate_sleep
  done
  echo "Requeued: $n / $total"
  pause
}

clean_ru()         { remove_by_pattern "*.ru"          '@[^ ]*\.ru>'; }
clean_azart()      { remove_by_pattern "@azart.in"     '@azart\.in>'; }
clean_overquota()  { remove_by_pattern "Gmail overquota" 'gmail\.com.*over.*quota|inbox is out of storage space'; }

requeue_deferred_match() {
  echo "Enter grep pattern for mailq (e.g. gmail.com):"
  read patt
  requeue_by_pattern "Custom requeue: $patt" "$patt"
}

clean_deferred_days() {
  local days
  read -rp "$(_ enter_days) " days
  days="${days:-5}"
  mapfile -t FILES < <(find "$POSTFIX_QUEUE_DIR/deferred" -type f -mtime +"$days" 2>/dev/null | head -n 2000)
  local total="${#FILES[@]}"
  [ "$total" -eq 0 ] && { echo "$(_ no_matches)"; pause; return; }
  echo -e "${BLUE}$(_ preview_header)${RESET} ($total files)"
  printf '%s\n' "${FILES[@]}" | head -n 30 | sed 's/^/  /'
  [ "$total" -gt 30 ] && echo "  ... ($((total-30)) more)"
  confirm_action "$total" || { pause; return; }
  local n=0
  for f in "${FILES[@]}"; do
    id="$(basename "$f")"
    [[ "$id" =~ ^[A-F0-9]+$ ]] || continue
    cmd "postsuper -d $id" && n=$((n+1))
    rate_sleep
  done
  echo "Deleted deferred: $n / $total"
  pause
}

clean_by_id() {
  read -rp "$(_ enter_queueid) " id
  validate_id "$id" || { echo "Invalid ID."; pause; return; }
  preview_ids <<< "$id"
  confirm_action 1 || { pause; return; }
  cmd "postsuper -d $id"
  pause
}

sample_preview() {
  echo "Enter grep pattern (e.g. \\.ru):"
  read patt
  mapfile -t IDS < <(list_ids_by "$patt")
  [ "${#IDS[@]}" -eq 0 ] && { echo "$(_ no_matches)"; pause; return; }
  printf "%s\n" "${IDS[@]}" | head -n 50 | preview_ids | show_and_pause
}

# «Одна кнопка» — собрать всё и удалить
clean_all_queues() {
  local days="${1:-5}"
  echo -e "${BLUE}Збір кандидатів для очищення...${RESET}"

  mapfile -t R1 < <(list_ids_by '@[^ ]*\.ru>' || true)
  mapfile -t R2 < <(list_ids_by '@azart\.in>' || true)
  mapfile -t R3 < <(list_ids_by 'gmail\.com.*over.*quota|inbox is out of storage space' || true)

  mapfile -t R4_FILES < <(find "$POSTFIX_QUEUE_DIR/deferred" -type f -mtime +"$days" 2>/dev/null || true)
  R4=()
  for f in "${R4_FILES[@]}"; do
    id="$(basename "$f")"
    [[ "$id" =~ ^[A-F0-9]+$ ]] && R4+=("$id")
  done

  mapfile -t ALL_IDS < <(printf "%s\n" "${R1[@]}" "${R2[@]}" "${R3[@]}" "${R4[@]}" | awk 'NF' | sort -u)

  local total="${#ALL_IDS[@]}"
  if [ "$total" -eq 0 ]; then
    echo "$(_ no_matches)"; pause; return
  fi

  echo -e "${BLUE}$(_ preview_header)${RESET} ($total IDs)"
  printf "%s\n" "${ALL_IDS[@]}" | head -n 25 | preview_ids | sed 's/^/  /'
  [ "$total" -gt 25 ] && echo "  ... ($((total-25)) more)"

  confirm_action "$total" || { pause; return; }

  queue_stats
  local n=0
  for id in "${ALL_IDS[@]}"; do
    is_whitelisted "$id" && { echo "SKIP (whitelisted): $id"; continue; }
    cmd "postsuper -d $id" && n=$((n+1))
    rate_sleep
  done
  echo "Removed: $n / matched: $total"
  queue_stats
  pause
}

##############################################################################
# SPAMASSASSIN: ПРАВИЛА/ТЕСТЫ
##############################################################################
escape_regex() { sed -e 's/[\/.^$*+?(){}[\]|\\]/\\&/g'; }

extract_domains_from_urls() {
  awk '
    {
      url=$0
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",url)
      if (url ~ /^https?:\/\/[^\/]+/) {
        host=url; sub(/^https?:\/\//,"",host); sub(/\/.*$/,"",host)
        n=split(host, a, ".")
        if (n>=2) {
          root=a[n-1]"."a[n]
          if (a[n-2] ~ /^(com|co|net|org|gov|edu|mil|ac|com?)$/ && n>=3) root=a[n-2]"."root
          print tolower(root)
        }
      }
    }
  ' | sort -u
}

next_rule_suffix() {
  local mx
  mx=$( (grep -ho 'PAYMENT_SPAM_[0-9][0-9]+' "$RULES_DIR"/*.cf 2>/dev/null; grep -ho 'PAYMENT_SPAM_[0-9][0-9]+' "$SA_LOCAL_CF" 2>/dev/null) \
        | sed 's/.*_//' | sort -n | tail -n1 )
  mx=${mx:-0}
  printf '%02d' $((10#$mx + 1))
}

generate_rules_from_eml() {
  local ts="$(TS)"
  local outfile="$RULES_DIR/generated_${ts}.cf"
  local lint_log="$LOG_DIR/lint_${ts}.log"
  local max_rules=200
  local added=0

  : > "$TMP_DIR/urls.tmp"
  : > "$TMP_DIR/emails.tmp"
  : > "$TMP_DIR/ips.tmp"
  for f in "$SPAM_EML_DIR"/*.eml; do
    [ -e "$f" ] || continue
    grep -Eoi 'https?://[^[:space:]]+' "$f" | sed 's/[)>",;]+$//' | sort -u >> "$TMP_DIR/urls.tmp"
    grep -Eoi '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b' "$f" | sort -u >> "$TMP_DIR/emails.tmp"
    grep -Eo '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' "$f" | sort -u >> "$TMP_DIR/ips.tmp"
  done
  sort -u -o "$TMP_DIR/urls.tmp" "$TMP_DIR/urls.tmp"
  sort -u -o "$TMP_DIR/emails.tmp" "$TMP_DIR/emails.tmp"
  sort -u -o "$TMP_DIR/ips.tmp" "$TMP_DIR/ips.tmp"

  echo "; Auto-generated rules $(date)" > "$outfile"

  if [ -s "$TMP_DIR/urls.tmp" ]; then
    mapfile -t DOMS < <(cat "$TMP_DIR/urls.tmp" | extract_domains_from_urls)
    DOMS=($(printf "%s\n" "${DOMS[@]}" | sort -u))
    for d in "${DOMS[@]}"; do
      [ "$added" -ge "$max_rules" ] && break
      local name="PAYMENT_SPAM_$(next_rule_suffix)"
      local safe_d; safe_d="$(echo "$d" | escape_regex)"
      {
        echo "uri_detail $name domain =~ /(^|\\.)$safe_d$/i"
        echo "describe   $name Auto domain match for $d"
        echo "score      $name 6.0"
        echo
      } >> "$outfile"
      added=$((added+1))
    done
  fi

  if [ -s "$TMP_DIR/emails.tmp" ]; then
    while read -r em; do
      [ -z "$em" ] && continue
      [ "$added" -ge "$max_rules" ] && break
      local name="PAYMENT_SPAM_$(next_rule_suffix)"
      local safe; safe="$(echo "$em" | escape_regex)"
      {
        echo "body       $name /$safe/i"
        echo "describe   $name Auto sender marker $em"
        echo "score      $name 4.0"
        echo
      } >> "$outfile"
      added=$((added+1))
    done < <(head -n 50 "$TMP_DIR/emails.tmp")
  fi

  say "Rules saved to $outfile"
  log "Generated $added rules → $outfile"

  spamassassin --lint -C /etc/mail/spamassassin -p "$outfile" >"$lint_log" 2>&1
  if [ $? -eq 0 ]; then
    echo "$(_ lint_ok)"
  else
    echo -e "${RED}$(_ lint_fail)${RESET}"
    echo "See: $lint_log"
  fi
  pause
}

add_manual_rule() {
  read -rp "Rule type (body/header/uri/uri_detail): " type
  read -rp "Rule name (e.g. PAYMENT_SPAM_XX or leave blank for auto): " name
  if [ -z "$name" ]; then name="PAYMENT_SPAM_$(next_rule_suffix)"; fi
  read -rp "Score (e.g. 6.0): " score

  local ts="$(TS)"; local outfile="$RULES_DIR/generated_manual_${ts}.cf"
  case "$type" in
    body)
      read -rp "Regex (without delimiters): " rgx
      rgx_esc="$(echo "$rgx" | escape_regex)"
      echo -e "body $name /$rgx_esc/i\nscore $name $score" >> "$outfile"
    ;;
    header)
      read -rp "Header name (e.g. Subject): " hdr
      read -rp "Regex (without delimiters): " rgx
      rgx_esc="$(echo "$rgx" | escape_regex)"
      echo -e "header $name $hdr =~ /$rgx_esc/i\nscore $name $score" >> "$outfile"
    ;;
    uri)
      read -rp "Regex for full URL (without delimiters): " rgx
      rgx_esc="$(echo "$rgx" | escape_regex)"
      echo -e "uri $name /$rgx_esc/i\nscore $name $score" >> "$outfile"
    ;;
    uri_detail)
      read -rp "Domain (e.g. example.tld): " dom
      dom_esc="$(echo "$dom" | escape_regex)"
      echo -e "uri_detail $name domain =~ /(^|\\.)$dom_esc$/i\nscore $name $score" >> "$outfile"
    ;;
    *) echo "Unknown type"; pause; return;;
  esac
  echo "Rule saved to $outfile"
  spamassassin --lint -C /etc/mail/spamassassin -p "$outfile" >/dev/null 2>&1 \
    && echo "$(_ lint_ok)" || echo -e "${YELLOW}$(_ lint_fail)${RESET}"
  pause
}

quick_backup_localcf() {
  local b="$BACKUP_DIR/local.cf_$(date +%Y%m%d_%H%M).bak"
  cp -a "$SA_LOCAL_CF" "$b" && echo "$(_ backup_made) $b" && log "Backup: $b"
}

list_backups() { ls -1t "$BACKUP_DIR"/local.cf_* 2>/dev/null | nl -w2 -s') '; }

restore_backup() {
  local list; list=$(list_backups)
  [ -z "$list" ] && { echo "$(_ no_backups)"; pause; return; }
  echo "$list"
  read -rp "$(_ choose_backup) " n
  local file; file=$(ls -1t "$BACKUP_DIR"/local.cf_* 2>/dev/null | sed -n "${n}p")
  [ -f "$file" ] || { echo "Invalid selection"; pause; return; }
  cp -a "$SA_LOCAL_CF" "$BACKUP_DIR/local.cf_pre_restore_$(TS).bak"
  cmd "cp '$file' '$SA_LOCAL_CF'" && echo "$(_ restored) $file"
  pause
}

diff_with_last_generated() {
  local last
  last=$(ls -1t "$RULES_DIR"/*.cf 2>/dev/null | head -n1)
  [ -f "$last" ] || { echo "No generated rules."; pause; return; }
  local diff_log="$LOG_DIR/localcf_diff_$(TS).log"
  diff -u "$SA_LOCAL_CF" "$last" | tee "$diff_log" | sed -n '1,200p'
  echo "Diff saved: $diff_log"
  pause
}

show_last_generated_path() {
  local last
  last=$(ls -1t "$RULES_DIR"/*.cf 2>/dev/null | head -n1)
  [ -f "$last" ] && echo "$(_ show_last_rules) $last" || echo "No generated rules."
  pause
}

test_single_eml() {
  read -rp "Path to .eml: " f
  [ -f "$f" ] || { echo "File not found."; pause; return; }
  local tlog="$LOG_DIR/sa_test_$(TS).log"
  spamassassin -D < "$f" | tee "$tlog" | show_and_pause
}

test_batch_eml() {
  local report="$LOG_DIR/sa_batch_$(TS).log"
  : > "$report"
  local cnt=0
  for f in "$SPAM_EML_DIR"/*.eml; do
    [ -e "$f" ] || continue
    echo "===== $f =====" | tee -a "$report"
    spamassassin -t < "$f" 2>/dev/null | tee -a "$report" | sed -n '1,60p' >/dev/null
    cnt=$((cnt+1))
  done
  echo "Batch tested: $cnt  → $report"
  pause
}

##############################################################################
# ЛОГИ (устойчивые top-функции)
##############################################################################
log_stream() {
  if [ -r /var/log/maillog ]; then
    cat /var/log/maillog
  else
    journalctl -u postfix -u spamassassin -n 5000 --no-pager 2>/dev/null || true
  fi
}

top_defer_reasons() {
  log_stream \
    | grep -i ' defer' \
    | awk -F': ' '{print $NF}' \
    | sed 's/ (in reply.*$//' | sed 's/[[:space:]]\+$//' | sed '/^$/d' \
    | sort | uniq -c | sort -nr | head -n5
}

top_sa_rules() {
  log_stream \
    | grep -i 'spamd' \
    | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[A-Z][A-Z0-9_]{2,}$/) cnt[$i]++} END {for (k in cnt) printf "%6d %s\n", cnt[k], k}' \
    | sort -nr | head -n10
}

logs_menu() {
  while true; do
    clear
    echo "==== Logs Menu ===="
    cat <<EOM
1) Останні 200 рядків /var/log/maillog (errors)
2) blocked|bounced|reject
3) .ru | .cn | .site спроби
4) Пошук за фразою
5) Топ-5 причин defer (за /var/log/maillog)
6) Топ-10 правил SpamAssassin (за логу)
0) Назад
EOM
    read -rp "→ " c
    case "$c" in
      1) grep -i 'error' /var/log/maillog | tail -n 200 | show_and_pause;;
      2) grep -Ei 'blocked|bounced|reject' /var/log/maillog | show_and_pause;;
      3) grep -Ei '\.ru|\.cn|\.site' /var/log/maillog | show_and_pause;;
      4) read -rp "$(_ enter_phrase) " p; grep -iF -- "$p" /var/log/maillog | show_and_pause;;
      5) top_defer_reasons | show_and_pause;;
      6) top_sa_rules | show_and_pause;;
      0) break;;
      *) echo "$(_ invalid_choice)"; pause;;
    esac
  done
}

##############################################################################
# ДИАГНОСТИКА
##############################################################################
diag_menu() {
  while true; do
    clear
    echo "==== Diagnostics Menu ===="
    cat <<EOM
1) Стан черги (active/deferred/hold) + підсумок
2) Кількість deferred (файлів)
3) Останні 50 рядків maillog
4) Дата/час зміни local.cf
5) Дата/час системи та таймзона
6) Статистика по *.ru у черзі (прев’ю)
0) Назад
EOM
    read -rp "→ " c
    case "$c" in
      1) queue_stats; postqueue -p | tail -n1; pause;;
      2) find "$POSTFIX_QUEUE_DIR/deferred" -type f 2>/dev/null | wc -l; pause;;
      3) tail -n 50 /var/log/maillog | show_and_pause;;
      4) stat -c '%y %n' "$SA_LOCAL_CF"; pause;;
      5) echo -n "System time: "; date; echo -n "Timezone: "; timedatectl 2>/dev/null | grep 'Time zone' || echo "N/A"; pause;;
      6) list_ids_by '@[^ ]*\.ru>' | head -n 100 | preview_ids | show_and_pause;;
      0) break;;
      *) echo "$(_ invalid_choice)"; pause;;
    esac
  done
}

##############################################################################
# МЕНЮ/ВЫБОР РЕЖИМА/ЯЗЫКА
##############################################################################
select_language() {
  echo "$(_ lang_select)"
  read -rp "→ " l
  case "$l" in
    2) LANG_CHOICE="EN";;
    *) LANG_CHOICE="UA";;
  esac
}

main_menu() {
  while true; do
    clear
    echo "==== Main Menu (${MODE}, ${LANG_CHOICE}) ===="
    cat <<EOM
1) Черга листів / Mail queue
2) SpamAssassin
3) Логи Postfix
4) Діагностика та статистика
5) Показати шлях до останнього generated.cf
6) Швидкий бекап local.cf зараз
7) Diff local.cf ↔ останній generated.cf
8) Почистити всі черги ( *.ru / @azart.in / Gmail overquota / deferred>N )
0) Вихід / Exit
EOM
    read -rp "→ " c
    case "$c" in
      1) queue_menu;;
      2) spam_menu;;
      3) logs_menu;;
      4) diag_menu;;
      5) show_last_generated_path;;
      6) quick_backup_localcf;;
      7) diff_with_last_generated;;
      8) read -rp "Скільки днів для deferred? (default 5): " dd; dd="${dd:-5}"; clean_all_queues "$dd";;
      0) exit 0;;
      *) echo "$(_ invalid_choice)"; pause;;
    esac
  done
}

queue_menu() {
  while true; do
    clear
    echo "==== Queue Menu (${MODE}, ${LANG_CHOICE}) ===="
    cat <<EOM
1) Показати чергу / Show queue
2) Видалити *.ru
3) Видалити @azart.in
4) Видалити Gmail overquota
5) Видалити deferred старше N днів
6) Видалити за QUEUE_ID
7) Requeue за патерном
8) Перегляд заголовків за QUEUE_ID
9) Сэмпл-превью по патерну (без дій)
10) Очистити все ( *.ru / @azart.in / Gmail overquota / deferred>N )
0) Назад / Back
EOM
    read -rp "→ " c
    case "$c" in
      1) show_queue; pause;;
      2) clean_ru;;
      3) clean_azart;;
      4) clean_overquota;;
      5) clean_deferred_days;;
      6) clean_by_id;;
      7) requeue_deferred_match;;
      8) view_message_headers;;
      9) sample_preview;;
      10) read -rp "Скільки днів для deferred? (default 5): " dd; dd="${dd:-5}"; clean_all_queues "$dd";;
      0) break;;
      *) echo "$(_ invalid_choice)"; pause;;
    esac
  done
}

spam_menu() {
  while true; do
    clear
    echo "==== SpamAssassin Menu (${MODE}, ${LANG_CHOICE}) ===="
    cat <<EOM
1) Додати правило вручну (manual)
2) Згенерувати правила з spam_emls/ (URL/e-mail/IP) + lint
3) Показати шлях до останнього згенерованого rules-файлу
4) Зробити швидкий бекап local.cf
5) Показати diff між local.cf та останнім generated.cf
6) Відкотити local.cf із backup/
7) Тест одного EML (spamassassin -D)
8) Тест пакету EML із spam_emls/
0) Назад
EOM
    read -rp "→ " c
    case "$c" in
      1) add_manual_rule;;
      2) quick_backup_localcf; generate_rules_from_eml;;
      3) show_last_generated_path;;
      4) quick_backup_localcf;;
      5) diff_with_last_generated;;
      6) restore_backup;;
      7) test_single_eml;;
      8) test_batch_eml;;
      0) break;;
      *) echo "$(_ invalid_choice)"; pause;;
    esac
  done
}

select_mode() {
  while true; do
    clear
    rotate_logs
    cat <<EOM
==========================================
   Postfix Admin Utility v1.3.1
==========================================
1) Симуляція / Simulation
2) Реальна робота / Real
0) Вихід / Exit
EOM
    read -rp "→ " m
    case "$m" in
      1) MODE="SIMULATION"; log "Started in simulation mode"; main_menu;;
      2) MODE="REAL"; log "Started in real mode"; main_menu;;
      0) exit 0;;
      *) echo "$(_ invalid_choice)"; sleep 1;;
    esac
  done
}

##############################################################################
# START
##############################################################################
require_root
check_binaries
acquire_lock
select_language
select_mode
