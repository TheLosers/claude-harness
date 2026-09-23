#!/bin/bash
# edit-guard.sh — Claude Code PreToolUse(Edit|Write) 훅
#
#   read-first    새 소스 파일을 만들기 전에 같은 폴더의 기존 파일을 읽었는지 본다
#   test-disable  테스트 파일에 테스트를 끄는 표시가 새로 붙는 것을 막는다
#
# 둘 다 승인을 묻는 게이트가 아니다. 「읽고 다시 해라」, 「끄지 말고 고쳐라」로 돌려보낸다.
# 설정: ~/.config/claude-harness/gates.conf (DISABLED_GATES, LOG_FILE, SOURCE_EXTENSIONS)
# 필요한 것: jq
# 한계: Read 호출 기록과 skip 패턴 증가를 확인하는 보조 장치다.
# 실제 파일 이해 여부, 테스트의 의미상 비활성화, 다른 도구를 통한 편집은 검증하지 않는다.

command -v jq >/dev/null 2>&1 || { printf 'edit-guard: jq가 필요합니다.\n' >&2; exit 2; }
input=$(cat)
fp=$(printf '%s' "$input" | jq -er '.tool_input.file_path | select(type == "string" and length > 0)') || {
  printf 'edit-guard: 유효한 file_path 문자열이 필요합니다.\n' >&2
  exit 2
}

LOG_FILE="$HOME/.claude/logs/harness-guard.jsonl"
SOURCE_EXTENSIONS='kt|java|ts|tsx|js|jsx|py|go|rb|rs|swift'
DISABLED_GATES=''
conf="${CLAUDE_HARNESS_CONF:-$HOME/.config/claude-harness/gates.conf}"
# shellcheck disable=SC1090
[ -f "$conf" ] && . "$conf"

enabled() { case " $DISABLED_GATES " in *" $1 "*) return 1 ;; esac; return 0; }

deny() { # $1=gate $2=reason
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg g "$1" --arg fp "$fp" \
    '{ts:$ts,guard:"edit",gate:$g,decision:"deny",file:$fp}' >> "$LOG_FILE" 2>/dev/null
  jq -n --arg r "$2" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# ── 1. 새 소스 파일을 만들기 전에 옆 파일을 읽었나 ─────────────────────────
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
if enabled read-first && [ "$tool" = "Write" ] && [ ! -e "$fp" ] \
   && printf '%s' "$fp" | grep -qE "\.($SOURCE_EXTENSIONS)$"; then
  case "$fp" in
    /tmp/*|/private/tmp/*|*/scratchpad/*|*/build/*|*/dist/*|*/node_modules/*|*/.git/*) ;;
    *)
      dir=$(dirname "$fp"); ext="${fp##*.}"
      # 같은 폴더에 참고할 기존 파일이 있을 때만 건다
      if find "$dir" -maxdepth 1 -name "*.$ext" -type f 2>/dev/null | grep -q .; then
        tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
        seen=0
        if [ -n "$tp" ] && [ -f "$tp" ]; then
          if jq -se --arg dir "$dir" '
            any(.[] | .. | objects;
              .type? == "tool_use" and .name? == "Read" and
              ((.input.file_path? // "") | split("/") | .[:-1] | join("/")) == $dir)
          ' "$tp" >/dev/null 2>&1; then
            seen=1
          fi
        fi
        if [ "$seen" -eq 0 ]; then
          sample=$(find "$dir" -maxdepth 1 -name "*.$ext" -type f 2>/dev/null | head -3 | tr '\n' ' ')
          deny "read-first" "새 소스 파일을 만들기 전에 같은 폴더의 기존 코드를 읽지 않았다. 다음 중 하나를 읽고 이름 짓는 법, 구조, 도메인 용어, import 순서를 확인한 뒤 그에 맞춰 다시 쓸 것: ${sample}"
        fi
      fi
      ;;
  esac
fi

# ── 2. 테스트를 끄지 않는다 ─────────────────────────────────────────────
# JUnit(@Disabled, @Ignore), pytest(skip), Jest·Mocha·Vitest(.skip, xit, xdescribe)
if enabled test-disable \
   && printf '%s' "$fp" | grep -qE '(/src/test/|/tests?/|Test\.(kt|java)$|_test\.(py|go)$|/test_[^/]*\.py$|\.(test|spec)\.[jt]sx?$)'; then
  skip_re='@(Disabled|Ignore)([^A-Za-z]|$)|@pytest\.mark\.skip|pytest\.skip\(|(^|[^A-Za-z])(it|test|describe)\.skip\(|(^|[^A-Za-z])x(it|test|describe)\('
  new=$(printf '%s' "$input" | jq -r '.tool_input.new_string // .tool_input.content // empty')
  old=$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty')
  new_cnt=$(printf '%s' "$new" | grep -cE "$skip_re")
  old_cnt=$(printf '%s' "$old" | grep -cE "$skip_re")
  if [ "${new_cnt:-0}" -gt "${old_cnt:-0}" ]; then
    deny "test-disable" "테스트를 끄는 표시를 새로 붙이지 않는다. 실패 원인을 찾아 고칠 것: 코드 버그면 코드를, 설정 오류면 설정을 고친다. API 키 같은 것이 없으면 사용자에게 알린다."
  fi
fi

exit 0
