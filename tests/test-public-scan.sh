#!/bin/bash
# 가짜 토큰/금지어와 임시 저장소만 쓴다. 실제 개인 denylist는 읽지 않는다.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
scan="$repo/scripts/check-public.sh"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
export CLAUDE_HARNESS_DENYLIST="$test_root/private-words"
printf '%s\n' 'fictional-internal-word' > "$CLAUDE_HARNESS_DENYLIST"
mkdir "$test_root/repo"
cd "$test_root/repo"
git init -q
git config user.name 'Harness Test'
git config user.email 'test@example.invalid'
passed=0
check() {
  expected=$1; label=$2; shift 2
  actual=0
  result=$(bash "$scan" "$@" 2>&1) || actual=$?
  [ "$actual" -eq "$expected" ] || { printf 'FAIL %s (exit %s)\n' "$label" "$actual"; exit 1; }
  passed=$((passed + 1))
  printf 'PASS %s\n' "$label"
}
printf 'safe example\n' > example.md
check 0 'clean directory' --path .
printf 'fictional-internal-word\n' > example.md
check 1 'private word in directory' --path .
case "$result" in *fictional-internal-word*) echo 'FAIL matched value leaked'; exit 1;; esac
check 2 'unknown option fails' --unknown
check 2 'missing directory fails' --path "$test_root/missing"
printf 'safe example\n' > example.md
git add example.md
check 0 'clean staged file' --staged
git commit -qm clean
# 문자열을 조합해 테스트 소스 자체에 완성된 토큰을 남기지 않는다.
printf 'gh%s_%036d\n' p 0 > example.md
git add example.md
check 1 'synthetic token staged' --staged
git commit -qm synthetic-fixture
printf 'safe again\n' > example.md
git add example.md
git commit -qm remove-fixture
check 0 'clean tracked file' --all
check 1 'removed token remains in history' --history
printf '%s scanner cases passed\n' "$passed"
