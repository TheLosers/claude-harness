# 반복문 안의 조회를 배치로 바꾼다

> **컬렉션의 원소마다 DB나 외부 API를 호출하는 N+1 패턴을 만들지 않는다.**

항목이 늘 때마다 조회도 늘어나는 구조를 피한다. 식별자를 모아 한 번에 조회하고 결과를 메모리에서 묶는다.
다음은 회사 코드와 무관한 예시다.

```kotlin
// 원소마다 조회한다.
for (order in orders) {
    val items = itemRepository.findByOrderId(order.id)
}

// 식별자를 모아 조회하고 주문별로 묶는다.
val orderIds = orders.map { it.id }.toSet()
val itemsByOrderId = itemRepository.findByOrderIdIn(orderIds)
    .groupBy { it.orderId }
```

- 애플리케이션 서비스와 도메인 서비스 모두 적용한다.
- 외부 API 호출도 배치 엔드포인트를 먼저 확인한다.
- JPA의 지연 로딩은 조회 목적에 맞게 `JOIN FETCH`나 `@EntityGraph`를 검토한다.
- 단건 조회 자체는 N+1이 아니다. `findById`를 한 번 호출하는 것은 이 규칙의 대상이 아니다.

실제 쿼리 수를 확인해 반복 조회가 남았는지 검증한다. 배치 API가 없거나 한 번에 조회할 수 없는 경우에는 그 제약을 밝히고 별도로 설계한다.
