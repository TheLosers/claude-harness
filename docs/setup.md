# 설치와 업데이트

## 규칙 연결

저장소를 `~/claude-harness`에 둔 경우, 기존 `~/.claude/CLAUDE.md`에 다음 한 줄을 추가한다. 기존 내용은 지우지 않는다.

```text
@~/claude-harness/CLAUDE.md
```

Claude Code의 상대 import는 import가 적힌 파일을 기준으로 해석한다. 따라서 저장소 안의 `@modules/...`는 그대로 쓸 수 있다. [공식 import 설명](https://code.claude.com/docs/en/memory#import-additional-files)

## 훅 연결 — 선택 사항

1. `jq --version`으로 jq가 있는지 확인한다.
2. [settings.example.json](../modules/gates/settings.example.json)의 `hooks.PreToolUse` 항목을 기존 `~/.claude/settings.json`에 합친다. 파일 전체를 덮어쓰지 않는다. 이미 같은 훅이 있으면 중복 등록하지 않는다.
3. 저장소 위치가 다르면 예시의 두 command 경로를 바꾼다.
4. Claude Code를 새로 시작하고 `/hooks`에서 등록 상태를 확인한다.

훅은 `Bash`, `Edit`, `Write` 입력만 대상으로 한다. 공개판 테스트는 입력을 직접 넣어 스크립트를 검사한 것이므로, Claude Code 버전별 통합 동작까지 검증했다는 뜻은 아니다. [공식 훅 설정과 차단 방식](https://code.claude.com/docs/en/hooks#pretooluse-decision-control)

## 환경별 설정

[gates.conf.example](../modules/gates/gates.conf.example)을 참고해 `~/.config/claude-harness/gates.conf`를 만든다. 기존 파일이 있으면 내용을 먼저 확인하고 필요한 항목만 바꾼다.

- `PROD_DB_HOSTS`: 접속을 막을 운영 DB 주소의 정규식. 기본값은 비어 있어 운영 DB 검사가 꺼져 있다. 예시 주소는 실제 환경을 보호하지 않는다.
- `STATE_DIR`, `MARKER_TTL_MIN`: 승인 표식 위치와 유효 시간. 기본 10분이다.
- `LOG_FILE`: 로컬 검사 기록. 명령 일부가 남으므로 저장소에 넣거나 외부로 공유하지 않는다.
- `DISABLED_GATES`: 적용하지 않을 게이트. 끄면 해당 검사는 실행하지 않는다.

설정은 셸 파일을 `source`해서 읽는다. 신뢰할 수 있는 본인 설정만 사용한다. 회사 정책과 접근 권한은 별도로 지켜야 한다.

## 공개 전 검사

[denylist.example](../denylist.example)을 참고해 개인 금지어 목록을 `~/.config/claude-harness/denylist`에 둔다. 실제 목록은 저장소 안에 복사하지 않는다.

```bash
cd ~/claude-harness
bash scripts/check-public.sh --path .
```

목록이 없으면 비밀값 모양만 검사하고 경고한다. 그 결과를 회사 정보까지 검사했다는 뜻으로 받아들이지 않는다. 이력 검사는 로컬에 있는 모든 ref의 커밋을 대상으로 한다.

Git 훅을 쓰려면 이 저장소에서 다음을 실행한다. 이미 `core.hooksPath`를 사용한다면 기존 훅과 합치는 방법부터 확인한다.

```bash
chmod +x .githooks/pre-commit .githooks/pre-push scripts/check-public.sh
git config --local core.hooksPath .githooks
```

`pre-commit`은 staged 파일을, `pre-push`는 커밋 이력을 검사한다. Git 훅은 clone만으로 활성화되지 않는다. 검사기가 놓치는 형식·단어도 있으므로 업로드할 파일 목록과 변경 내용은 직접 확인한다.

## 업데이트와 제거

업데이트 전 `git status`로 로컬 변경을 확인한다. 변경이 없다면 `git pull --ff-only` 후 테스트를 다시 실행한다. 충돌이나 로컬 변경이 있으면 먼저 내용을 비교한다.

제거할 때는 직접 추가한 `@import` 한 줄과 해당 command hook 항목만 삭제한다. Git 훅 경로도 이 저장소에서 설정한 값인지 확인한 뒤 해제한다. 기존 Claude 설정과 회사별 설정 파일은 함께 지우지 않는다.
