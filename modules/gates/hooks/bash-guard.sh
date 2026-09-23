#!/bin/bash
# bash-guard.sh — Claude Code PreToolUse(Bash) 훅
#
# 되돌리기 어려운 명령을 승인 없이 실행하지 못하게 막는다.
#   db-write        DB 클라이언트로 DDL/DML 실행
#   prod-db         운영 DB 접속 (조회 포함, 표식으로도 못 푼다)
#   pr-review       gh 로 PR 리뷰 등록
#   pr-merge        gh pr merge
#   browser-kill    브라우저 프로세스 종료
#   push-file-list  git push — 막지 않고 올라갈 파일 목록만 보여 준다
#
# 원래 사용 환경에서 ask가 확인창 없이 통과하는 것을 관찰했다. 다른 버전까지 단정하지 않는다.
# 명시적으로 deny로 막고, 사용자가 승인했을 때만 "승인 표식" 파일로 한 번 통과시킨다.
# 자세한 설명: ../details/why-deny-and-marker.md
#
# 설정: ~/.config/claude-harness/gates.conf (예시는 ../gates.conf.example)
# 필요한 것: jq
# 한계: 셸/SQL 파서가 아닌 문자열 검사다. 변수·별칭·간접 실행은 놓칠 수 있다.
# 승인 표식은 인증 수단이 아니다. 승인 대상은 하나의 명령으로 실행한다.
# 같은 명령의 다른 게이트도 계속 검사하며, 뒤에서 막혀도 앞에서 쓴 표식은 복구하지 않는다.
# 로그에는 명령 일부가 남으므로 자격 증명을 명령 인자로 넣지 않는다.

command -v jq >/dev/null 2>&1 || { printf 'bash-guard: jq가 필요합니다.\n' >&2; exit 2; }
input=$(cat)
cmd=$(printf '%s' "$input" | jq -er '.tool_input.command | select(type == "string" and length > 0)') || {
  printf 'bash-guard: 유효한 command 문자열이 필요합니다.\n' >&2
  exit 2
}

# ── 설정 ────────────────────────────────────────────────────────────────
STATE_DIR="$HOME/.claude/state"
LOG_FILE="$HOME/.claude/logs/harness-guard.jsonl"
MARKER_TTL_MIN=10
PROD_DB_HOSTS=''                                   # 정규식. 비어 있으면 prod-db 게이트를 끈다
DB_CLIENTS='mysql|mysqlsh|mycli|mariadb|psql|pgcli'
BROWSER_PATTERN='Google Chrome|Chromium|chromium|chrome'
DISABLED_GATES=''                                  # 끌 게이트 이름을 띄어 써서 나열
conf="${CLAUDE_HARNESS_CONF:-$HOME/.config/claude-harness/gates.conf}"
# shellcheck disable=SC1090
[ -f "$conf" ] && . "$conf"

enabled() { case " $DISABLED_GATES " in *" $1 "*) return 1 ;; esac; return 0; }

log_event() { # $1=gate $2=decision
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg g "$1" --arg d "$2" \
    --arg cmd "$(printf '%.200s' "$cmd")" --arg cwd "$(printf '%s' "$input" | jq -r '.cwd // empty')" \
    '{ts:$ts,guard:"bash",gate:$g,decision:$d,cmd:$cmd,cwd:$cwd}' >> "$LOG_FILE" 2>/dev/null
}

deny() { # $1=gate $2=reason
  log_event "$1" "deny"
  jq -n --arg r "$2" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# 승인 표식을 확인한다. 있으면 지우고(1회용) 0 을 돌려준다.
# 표식 파일에는 대상(테이블명, PR 번호, PID)이나 any 를 적는다.
# $1=표식 파일 이름 $2=대상 비교 방식(fixed | number)
consume_marker() {
  local f="$STATE_DIR/$1" want
  [ -f "$f" ] || return 1
  [ -n "$(find "$f" -mmin -"$MARKER_TTL_MIN" 2>/dev/null)" ] || return 1   # 오래된 표식은 무효
  want=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  [ -z "$want" ] && return 1
  if [ "$want" != "any" ]; then
    if [ "$2" = "number" ]; then
      case "$want" in *[!0-9]*) return 1 ;; esac
      printf '%s' "$cmd" | grep -qE "(^|[^0-9])$want([^0-9]|$)" || return 1
    else
      printf '%s' "$cmd" | grep -qF -- "$want" || return 1
    fi
  fi
  rm -f "$f"
}

marker_steps() { # $1=표식 파일 이름 $2=적을 대상 설명
  printf '순서: (1) 무엇을 실행하고 무엇이 바뀌는지 사용자에게 보인다 -> (2) 사용자 승인을 받는다 -> (3) mkdir -p %s 하고 %s 을(를) %s/%s 에 적는다 (any 도 가능) -> (4) 같은 명령을 다시 실행한다. 표식은 %s분 유효하고 한 번 쓰면 사라진다. 승인을 받지 않은 채 표식을 만들지 말 것 - 그러면 이 게이트는 없는 것과 같다.' \
    "$STATE_DIR" "$2" "$STATE_DIR" "$1" "$MARKER_TTL_MIN"
}

# ── 1. 운영 DB 접속 — 조회를 포함해 막는다. 표식으로도 풀지 않는다 ─────────
if enabled prod-db && [ -n "$PROD_DB_HOSTS" ] \
   && printf '%s' "$cmd" | grep -qE "($DB_CLIENTS)[^|;&]*($PROD_DB_HOSTS)"; then
  deny "prod-db" "운영 DB 에는 이 세션에서 접속하지 않는다 (조회 포함). 운영 데이터가 필요하면 사용자에게 조회를 부탁할 것."
fi

# ── 2. DB 쓰기 — DDL/DML 은 승인 표식이 있을 때만 ─────────────────────────
if enabled db-write \
   && printf '%s' "$cmd" | grep -qiE "(^|[/[:space:]])($DB_CLIENTS)([[:space:]]|$)" \
   && printf '%s' "$cmd" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+[[:alnum:]_.`"]+[[:space:]]+set|delete[[:space:]]+from|alter[[:space:]]+table|drop[[:space:]]+(table|index|database|schema)|create[[:space:]]+(table|index|database|schema)|truncate[[:space:]]|replace[[:space:]]+into)'; then
  if consume_marker db-write-approved fixed; then
    log_event "db-write" "allow"
  else
    deny "db-write" "DB 쓰기(DDL/DML)는 승인 없이 실행하지 않는다. SQL 전문을 보이고 무엇이 바뀌고 무엇이 지워지는지 밝힐 것. $(marker_steps db-write-approved '대상 테이블명')"
  fi
fi

# ── 3. PR 리뷰 등록 ─────────────────────────────────────────────────────
# 조회와 등록이 같은 명령·경로를 쓴다. 제출 플래그나 쓰기 신호가 있을 때만 건다.
if enabled pr-review && {
     { printf '%s' "$cmd" | grep -qE 'gh[[:space:]]+pr[[:space:]]+review' && \
       printf '%s' "$cmd" | grep -qE -- '--approve|--request-changes|--comment|--body|(^|[[:space:]])-[abcr]([[:space:]]|$)'; } || \
     { printf '%s' "$cmd" | grep -qE 'gh[[:space:]]+api[^|;&]*pulls/[0-9]+/reviews' && \
       printf '%s' "$cmd" | grep -qE '(-X|--method)[[:space:]]+POST|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)[[:space:]]'; }; }; then
  if consume_marker pr-review-approved number; then
    log_event "pr-review" "allow"
  else
    deny "pr-review" "PR 리뷰 등록은 승인 없이 하지 않는다. 리뷰 내용 전체를 대화로 먼저 보일 것. $(marker_steps pr-review-approved 'PR 번호')"
  fi
fi

# ── 4. PR 머지 ──────────────────────────────────────────────────────────
if enabled pr-merge && printf '%s' "$cmd" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge'; then
  if consume_marker pr-merge-approved number; then
    log_event "pr-merge" "allow"
  else
    deny "pr-merge" "PR 머지는 승인 없이 하지 않는다. 「완료되면」「이어서 해 줘」는 머지 허가가 아니다. 머지할 PR 번호와 제목, 무엇이 들어가는지 보일 것. $(marker_steps pr-merge-approved 'PR 번호')"
  fi
fi

# ── 5. 브라우저 종료 ────────────────────────────────────────────────────
# 사용자가 같은 브라우저로 다른 일을 하고 있을 수 있다. 종료하면 탭과 로그인 세션이 함께 사라진다.
# 명령문에 브라우저 이름이 있거나, 종료 대상 PID 가 실제로 브라우저일 때만 건다.
if enabled browser-kill && printf '%s' "$cmd" | grep -qE '(^|[;&|(`[:space:]])(kill|pkill|killall)([[:space:]]|$)'; then
  target=0
  if printf '%s' "$cmd" | grep -qiE "$BROWSER_PATTERN"; then
    target=1
  else
    n=0
    for pid in $(printf '%s' "$cmd" | tr '[:space:]' '\n' | grep -E '^[0-9]{2,7}$'); do
      n=$((n + 1)); [ "$n" -gt 8 ] && break
      ps -p "$pid" -o command= 2>/dev/null | grep -qiE "$BROWSER_PATTERN" && { target=1; break; }
    done
  fi
  if [ "$target" -eq 1 ]; then
    if consume_marker browser-kill-approved number; then
      log_event "browser-kill" "allow"
    else
      deny "browser-kill" "브라우저를 승인 없이 종료하지 않는다. 떠 있는 브라우저와 탭 수를 보고하고 왜 종료하는지 밝힐 것. 연결에 실패했다고 재시도를 반복하지 말 것 - 탭만 늘어난다. $(marker_steps browser-kill-approved '종료할 PID')"
    fi
  fi
fi

# ── 6. git push — 막지 않는다. 올라갈 파일 목록을 보여 준다 ─────────────────
# 푸시는 되돌릴 수 없다. 지목받지 않은 파일이 섞였는지 올리기 직전에 볼 수 있게 한다.
if enabled push-file-list \
   && printf '%s' "$cmd" | grep -qE '(^|[;&|(`[:space:]])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)' \
   && ! printf '%s' "$cmd" | grep -qE -- '--dry-run|--help|(^|[[:space:]])-h([[:space:]]|$)'; then
  repo=$(printf '%s' "$cmd" | sed -nE 's/.*(^|[;&|[:space:]])cd[[:space:]]+([^[:space:];&|]+).*/\2/p' | head -1)
  [ -z "$repo" ] && repo=$(printf '%s' "$cmd" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
  [ -z "$repo" ] && repo=$(printf '%s' "$input" | jq -r '.cwd // empty')
  repo="${repo/#\~/$HOME}"
  files=$(git -C "$repo" diff --stat '@{u}..HEAD' 2>/dev/null || git -C "$repo" diff --stat origin/HEAD..HEAD 2>/dev/null)
  [ -z "$files" ] && files="(올라갈 파일 목록을 뽑지 못했다. 새 브랜치일 수 있다. git status 와 git log 로 직접 확인할 것)"
  log_event "push-file-list" "allow"
  printf '[push-file-list] 올라갈 파일 — 지목받지 않은 파일이 섞였는지 확인할 것:\n%s\n' "$files"
  exit 0
fi

exit 0
