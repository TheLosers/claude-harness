#!/bin/bash
# check-public.sh — 공개 저장소에 올리면 안 되는 문자열을 찾는다.
#
# 푸시한 것은 되돌릴 수 없다. 지운 커밋도 히스토리에 남아 누구나 읽는다.
# 그래서 커밋과 푸시 직전에 막는다.
#
# 두 가지를 본다.
#   1. 비밀값 모양의 문자열 — 토큰, 키, 비밀번호. 패턴은 이 파일에 있다.
#   2. 개인 금지어 — 회사 이름, 사내 서비스 이름, 동료 이름, 사내 도메인.
#      이 목록은 저장소 밖(~/.config/claude-harness/denylist)에 둔다.
#      저장소 안에 두면 그 목록이 공개된다.
#
# 쓰는 법:
#   check-public.sh            커밋하려고 올려 둔(staged) 변경만 본다 — pre-commit 훅
#   check-public.sh --all      지금 추적 중인 파일 전체를 본다
#   check-public.sh --history  모든 커밋의 모든 변경을 본다 — pre-push 훅
#   check-public.sh --path DIR git 메타데이터를 제외한 폴더 전체를 본다
#
# 찾으면 종료 코드 1 로 끝나고, 어느 파일 몇째 줄인지 보여 준다.

set -eu
mode="${1:---staged}"
denylist="${CLAUDE_HARNESS_DENYLIST:-$HOME/.config/claude-harness/denylist}"
case "$mode" in
  --path) cd "${2:?검사할 폴더를 지정하세요}" || exit 2 ;;
  --staged|--all|--history)
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "git 저장소 안에서 실행하세요." >&2; exit 2; }
    cd "$repo_root" || exit 2 ;;
  *) echo "모르는 옵션: $mode" >&2; exit 2 ;;
esac

# 비밀값 모양. 한 줄에 하나, 확장 정규식.
secret_patterns=(
  'hvs\.[A-Za-z0-9_-]{20,}'                    # HashiCorp Vault 토큰
  '(^|[^A-Za-z0-9])s\.[A-Za-z0-9]{24}([^A-Za-z0-9]|$)'  # Vault 옛 형식 토큰
  'ATATT[A-Za-z0-9_=-]{20,}'                   # Atlassian API 토큰
  'gh[pousr]_[A-Za-z0-9]{36}'                  # GitHub 토큰
  'github_pat_[A-Za-z0-9_]{40,}'               # GitHub 세분화 토큰
  'AKIA[0-9A-Z]{16}'                           # AWS 액세스 키
  'xox[abprs]-[A-Za-z0-9-]{10,}'               # Slack 토큰
  'sk-ant-[A-Za-z0-9_-]{20,}'                  # Anthropic API 키
  'sk-(proj-)?[A-Za-z0-9]{32,}'                # OpenAI API 키
  'figd_[A-Za-z0-9_-]{20,}'                    # Figma 개인 토큰
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'         # 개인 키
  '(api[_-]?key|secret|password|passwd|token)["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\''[:space:]]{12,}["'\'']'  # 이름=값 꼴
)

# 이 머신에만 있는 경로도 막는다. 공개판에는 ~ 로 써야 한다.
home_pattern=$(printf '%s' "$HOME" | sed 's/[][\.*^$/]/\\&/g')

# 검사할 내용을 "파일:줄:내용" 꼴로 뽑는다.
collect() {
  case "$mode" in
    --staged)
      git diff --cached --name-only --diff-filter=ACMR -z \
        | while IFS= read -r -d '' f; do
            git show ":$f" 2>/dev/null | grep -nI '' | sed "s|^|$f:|"
          done
      ;;
    --all)
      git ls-files -z \
        | while IFS= read -r -d '' f; do
            [ -f "$f" ] && grep -nI '' "$f" | sed "s|^|$f:|"
          done
      ;;
    --history)
      # diff 대신 커밋별 파일을 읽어 merge에서만 추가된 내용도 검사한다.
      git rev-list --all | while IFS= read -r rev; do
        git ls-tree -rz --name-only "$rev" | while IFS= read -r -d '' f; do
          git show "$rev:$f" | grep -nI '' | sed "s|^|$rev:$f:|"
        done
      done
      ;;
    --path)
      find . -name .git -prune -o -type f -print0 \
        | while IFS= read -r -d '' f; do
            grep -nI '' "$f" | sed "s|^|${f#./}:|"
          done
      ;;
    *) echo "모르는 옵션: $mode" >&2; exit 2 ;;
  esac
}

content=$(collect)
[ -z "$content" ] && exit 0

# 이 검사 스크립트와 금지어 예시 파일은 패턴을 설명하느라 패턴 비슷한 글자를 담는다. 비밀값 검사에서만 뺀다.
self_filter='^([0-9a-f]+:)?(scripts/check-public\.sh|denylist\.example):'
found=0

report() { # $1=제목 $2=매치 줄들
  [ -z "$2" ] && return 0
  found=1
  printf '\n\033[31m[막음] %s\033[0m\n' "$1"
  # 비밀값 자체는 출력하지 않고 고칠 위치만 보여 준다.
  printf '%s\n' "$2" | head -20 | sed -E 's/^(([0-9a-f]+:)?[^:]+:[0-9]+):.*/  \1: [내용 숨김]/'
  n=$(printf '%s\n' "$2" | wc -l | tr -d ' ')
  [ "$n" -gt 20 ] && printf '  ... 그 밖에 %s줄\n' $((n - 20))
  return 0
}

for p in "${secret_patterns[@]}"; do
  hits=$(printf '%s\n' "$content" | grep -vE "$self_filter" | grep -E -- "$p" || true)
  report "비밀값 모양: $p" "$hits"
done

hits=$(printf '%s\n' "$content" | grep -E -- "$home_pattern" || true)
report "이 머신의 홈 경로 ($HOME) — ~ 로 바꿀 것" "$hits"

if [ -f "$denylist" ]; then
  # 빈 줄과 # 주석은 뺀다. 대소문자는 가리지 않는다.
  words=$(grep -vE '^[[:space:]]*(#|$)' "$denylist" || true)
  if [ -n "$words" ]; then
    hits=$(printf '%s\n' "$content" | grep -iF -f <(printf '%s\n' "$words") || true)
    report "개인 금지어 ($denylist)" "$hits"
  fi
else
  printf '\033[33m[주의] 금지어 목록이 없습니다: %s\n       회사·서비스·동료 이름은 검사하지 못했습니다. denylist.example 을 참고해 만드세요.\033[0m\n' "$denylist" >&2
fi

if [ "$found" -eq 1 ]; then
  printf '\n위 줄을 고친 뒤 다시 시도하세요. 오탐이면 그 줄을 바꿔 쓰거나 금지어 목록을 고치세요.\n'
  printf '검사를 건너뛰는 --no-verify 는 쓰지 마세요. 푸시한 것은 되돌릴 수 없습니다.\n'
  exit 1
fi
exit 0
