# 백엔드 규칙

1. **컬렉션을 돌며 원소마다 DB나 외부 API를 호출하지 않는다.** 식별자를 모아 배치 조회하고 메모리에서 묶는다. ([이유와 예시](details/no-n-plus-one.md))
2. **DDL/DML은 SQL 전문과 대상 환경을 보이고 매번 승인받은 뒤 실행한다.** 조직별 접속 정보와 승인 절차는 저장소 밖에서 관리한다. ([승인 절차](../gates/details/why-deny-and-marker.md))
