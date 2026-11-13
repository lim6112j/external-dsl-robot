# robotdsl 작성 가이드

이 문서는 `.robot` 파일을 **처음부터 끝까지 직접 쓰는 방법**을 설명합니다.
문법의 전체 목록은 [`README.md`](../README.md)에 있고, 이 문서는 **어떻게
조립하는지**에 초점을 맞춥니다.

대상: VDA 5050 **v3.0.0** (존(zoneset) 포함).

---

## 목차

1. [가장 작은 파일](#1-가장-작은-파일)
2. [다섯 가지 기본 규칙](#2-다섯-가지-기본-규칙)
3. [헤더 선언](#3-헤더-선언)
4. [주문(order) 쓰기](#4-주문order-쓰기)
5. [액션](#5-액션)
6. [즉시 제어(instant)](#6-즉시-제어instant)
7. [존(zoneset) 쓰기](#7-존zoneset-쓰기)
8. [전체 문법 한눈에 보기](#8-전체-문법-한눈에-보기)
9. [자주 쓰는 패턴](#9-자주-쓰는-패턴)
10. [컴파일하고 확인하기](#10-컴파일하고-확인하기)
11. [오류 메시지 해설](#11-오류-메시지-해설)
12. [작성 요령](#12-작성-요령)

---

## 1. 가장 작은 파일

아래 내용을 `first.robot`로 저장하세요.

```robotdsl
robot "acme" "AMR-001"

instant "정지" {
  action "startPause"
}
```

컴파일:

```bash
robotdsl compile first.robot
```

출력:

```json
{"actions":[{"actionId":"startpause-1","actionType":"startPause","blockingType":"NONE"}],
 "headerId":1,"manufacturer":"acme","serialNumber":"AMR-001",
 "timestamp":"2026-11-13T12:00:00.000Z","version":"3.0.0"}
```

`headerId`, `timestamp`, `version`, `actionId`는 **직접 쓰지 않았습니다**. 컴파일러가
채워줍니다. 이것이 이 DSL의 전부입니다 — 운영자는 *무슨 일이 일어나야 하는지*만
쓰고, 표준이 요구하는 나머지는 컴파일러가 맡습니다.

---

## 2. 다섯 가지 기본 규칙

### 2.1 이름은 항상 따옴표로

```robotdsl
robot "acme" "AMR-001"
order "order-1" { ... }
node "RK-AM" at (12.5, 3.0) { ... }
zone "welding-corner" blocked { ... }
```

이유는 단순합니다. **예약어가 하나도 없기 때문**입니다. 실제 지도·노드 이름인
`pumpenhaus_1`, `MONTAGE`, `plant-b/l1`, `RK-AM`을 그대로 쓸 수 있고, 공백이나
점, 대시도 들어갑니다.

### 2.2 블록은 중괄호

들여쓰기는 전혀 영향을 주지 않습니다. 아래 두 개는 완전히 같은 파일입니다.

```robotdsl
order "o" { node "a" at (0,0) { action "pick" } }
```

```robotdsl
order "o" {
  node "a" at (0, 0) {
    action "pick"
  }
}
```

### 2.3 수식어 순서는 자유

```robotdsl
action "pick" blocking HARD describe "그랩" with { loadId = "KLT-42" }
action "pick" describe "그랩" with { loadId = "KLT-42" } blocking HARD
action "pick" with { loadId = "KLT-42" } blocking HARD describe "그랩"
```

셋 다 같습니다. 순서를 외울 필요가 없습니다.

### 2.4 키워드 대소문자 무관

`NODE`, `Node`, `node`는 모두 같습니다. `NONE`과 `none`도 같습니다.

### 2.5 주석 세 종류

```robotdsl
# 해시 주석
-- 대시대시 주석
/* 블록
   주석 */
```

---

## 3. 헤더 선언

파일 맨 위에 쓰는 선택 선언입니다. **전부 optional**이며, CLI 플래그가 기본값을
제공합니다.

```robotdsl
robot "acme" "AMR-001"      # 제조사, 시리얼번호 — 메시지의 수신자
map "plant-b"               # 노드 위치의 기본 mapId
version 3.0.0               # 컴파일러 대상과 반드시 일치해야 함
header 42                   # 시작 headerId
timestamp "2026-11-13T12:00:00.000Z"
```

| 선언 | 빠졌을 때 |
|---|---|
| `robot` | `--manufacturer` / `--serial-number`로 대체, 둘 다 없으면 오류 |
| `map` | 노드마다 `on map "..."`을 써야 함 |
| `version` | 컴파일러 대상인 `3.0.0` |
| `header` | `--header-id` 값, 기본 1 |
| `timestamp` | 현재 UTC 시각 |

> **파일이 이깁니다.** 파일에 `header 42`가 있으면 `--header-id 7`을 줘도 42가
> 나갑니다. 파일은 자기 메시지의 주인이기 때문입니다.

---

## 4. 주문(order) 쓰기

주문은 **노드**와 **엣지**가 번갈아 나열된 경로입니다.

### 4.1 최소 형태

```robotdsl
order "o1" {
  node "a" at (0, 0)
}
```

노드 하나만 있어도 유효한 주문입니다(엣지는 비워도 됨).

### 4.2 노드, 엣지, go

```robotdsl
order "order-pallet-1" {
  node "RK-AM" at (12.5, 3.0) {          # 랙 도착
    action "pick"
  }
  edge "e-1" speed 0.8                   # 복도 통과
  node "CHG-01" at (0.0, 0.0) {          # 컨베이어 도착
    action "drop"
  }
}
```

`go to`는 **엣지 + 노드**를 한 줄로 쓰는 축약입니다.

```robotdsl
go to "CHG-01" at (0.0, 0.0) via "e-2" speed 0.5 {
  action "drop"
}
```

위는 아래와 정확히 같습니다.

```robotdsl
edge "e-2" speed 0.5
node "CHG-01" at (0.0, 0.0) {
  action "drop"
}
```

`go`는 노드 수식어와 엣지 수식어를 **모두** 받습니다. `via "e-2"`는 연결되는
엣지의 이름을 짓는 것입니다.

### 4.3 위치와 방향

```robotdsl
node "a" at (12.5, 3.0)                    # x, y
node "b" at (0.0, 0.0, 1.5708)             # x, y, theta
node "c" at (7.0, 1.0) facing 0.5          # at + facing = at (x, y, theta)
node "d" at (1.0, 1.0) on map "plant-b-l2" # 맵 지정
```

- `at`은 미터 단위 좌표입니다.
- `theta`는 라디안이며 `[-π, π]` 범위여야 합니다.
- `on map "..."`을 생략하면 파일 맨 위의 `map` 선언을 물려받습니다.
- `mapId`를 끝내resolve 못 만들면(파일에도 `map`이 없고 노드에도 `on map`이 없으면)
  오류입니다. 위치가 있는 노드는 반드시 어느 맵 위인지 알아야 합니다.

정밀도 허용치:

```robotdsl
node "a" at (1.0, 1.0) deviation (0.1, 0.1, 0.0) deviation_theta 0.2
```

`deviation (a, b, theta)`는 도달 판정용 타원, `deviation_theta`는 각도 허용치입니다.

### 4.4 base와 horizon

`base`와 `route`는 `released: true`(이미 실행해도 좋다), `horizon`은
`released: false`(앞으로 계획된 구간)입니다.

```robotdsl
order "o1" {
  base {
    node "a" at (0, 0)
    edge "e1"
    node "b" at (1, 1)
  }
  horizon {
    edge "e2"
    node "c" at (2, 2)
  }
}
```

`sequenceId`는 base와 horizon을 넘어 **연속해서** 증가합니다. 위 경우 노드가
0, 2, 4이고 엣지가 1, 3입니다.

세그먼트 키워드를 아예 쓰지 않으면 전부 `base`로 취급합니다.

### 4.5 엣지 수식어

엣지는 **노드와 번갈아** 나와야 합니다. 아래는 수식어만 보여주는 예시이고, 실제
파일에서는 각 엣지 사이에 노드가 들어갑니다(4.4의 교대 규칙 참조).

```robotdsl
node "a" at (0, 0)
edge "e1" describe "메인 복도" speed 0.8 length 14.2
node "b" at (14, 0)
edge "e2" maxheight 2.0 minloadheight 0.1
node "c" at (14, 10)
edge "e3" orientation 1.0 orientation_type global reachbefore true maxrotation 0.5
node "d" at (20, 10)
edge "e4" corridor 0.5 0.5 ref contour release_required true release_loss return
node "e" at (20, 20)
edge "e5" direction "left"
node "f" at (25, 20)
```

| 수식어 | 의미 |
|---|---|
| `describe` | 사람이 읽는 설명 |
| `speed` | 최고 속도 (m/s) |
| `length` | 엣지 길이 (m) |
| `maxheight` | 로봇+하적 포함 최고 높이 (m) |
| `minloadheight` | 하역장치 최저 높이 (m) |
| `orientation` | 엣지 위 방향 (rad) |
| `orientation_type global\|tangential` | 기준 좌표계 / 엣지 접선 |
| `direction` | 유도형 로봇의 분기 방향 |
| `reachbefore true\|false` | 엣지 진입 전 회전 완료 여부 |
| `maxrotation` | 최고 회전 속도 (rad/s) |
| `corridor <좌> <우> [ref ...] [release_required ...] [release_loss ...]` | 궤도 이탈 허용 폭 |
| `trajectory ...` | NURBS 궤적 |

`corridor`의 선택 인자:

```robotdsl
corridor 0.5 0.5                                  # 좌 0.5m, 우 0.5m
corridor 0.5 0.5 ref kinematic_center             # 기준점: 운동학 중심
corridor 0.5 0.5 ref contour release_required true
corridor 0.5 0.5 release_loss stop                # 해제 시 동작: STOP 또는 RETURN
```

`trajectory`:

```robotdsl
trajectory degree 3 knots [0, 0, 0, 1, 1, 1] controlpoints [(0, 0), (1, 1), (2, 0)]
```

`controlpoints`는 필수이고, 각 점은 `(x, y)` 또는 `(x, y, weight)`입니다.

---

## 5. 액션

```robotdsl
action "pick" blocking HARD describe "팔레트 집기" retriable with {
  loadId = "KLT-42"
  loadType = "EPAL"
  duration = 4
  ok = true
  tags = ["a", "b"]
}
```

| 수식어 | 의미 |
|---|---|
| `blocking none\|soft\|single\|hard` | 다른 동작과 병렬 가능 정도 |
| `describe` | 사람이 읽는 설명 |
| `retriable` | 실패 시 재시도 가능 상태로 진입 |
| `with { ... }` | 액션 파라미터 (`key = value`) |

`with` 값은 문자열, 숫자, 불리언, 배열을 쓸 수 있습니다.

### blockingType 기본값 — 가장 헷갈리는 부분

컨텍스트마다 기본값이 다릅니다. 이건 임의가 아니라 표준의 규칙입니다.

| 위치 | 기본값 | 이유 |
|---|---|---|
| 주문 액션 (노드·엣지) | `HARD` | 표준의 기본값. 액션을 마치고 이동 |
| 즉시 액션 (`instant`) | `NONE` | v3.0.0이 즉시액션의 enum을 `NONE`만 허용 |
| 존 액션 (entry/during/exit) | `NONE` | 존 통과 중에도 병렬 실행 |

따라서 아래는 **의도적으로** 아무 blocking도 쓰지 않습니다.

```robotdsl
instant "일시정지" {
  action "startPause"        # 자동으로 NONE
}
```

반대로 즉시 액션에 `blocking HARD`를 쓰면 컴파일 오류입니다.

```
instant action 'startPause': blockingType must be NONE in VDA 5050 v3.0.0: ...
```

### actionId는 자동 생성

`action "pick"`이 세 번 나오면 `pick-1`, `pick-2`, `pick-3`가 됩니다. 메시지 안에서
고유하고, 소스가 같으면 항상 같은 값이 나옵니다(재현 가능).

---

## 6. 즉시 제어(instant)

각 `instant` 블록은 `instantActions` 메시지 하나가 됩니다. 라벨은 파일 이름에만
쓰이고 메시지 내용에는 들어가지 않습니다.

```robotdsl
instant "정지" {
  action "startPause"
  action "stateRequest"
}

instant "재개" {
  action "stopPause"
}

instant "중단" {
  action "cancelOrder" describe "운영자 중단"
}
```

파일에 `instant`이 세 개면 메시지도 세 개, 파일도 세 개 나옵니다.

---

## 7. 존(zoneset) 쓰기

존은 지도 자체를 고치지 않고 내비게이션을 제한하는 방법입니다. 한 zoneset은 한
맵에 속합니다.

```robotdsl
zoneset "zs-floor1" on map "plant-b" describe "1층 내비게이션 제약" {
  zone "welding-corner" describe "용접 셀, 출입 금지" blocked {
    polygon (0, 0) (5, 0) (5, 5) (0, 5)
  }
}
```

### 7.1 폴리곤은 항상 쓴다

**모든** 존은 `vertices`가 필수입니다. 존 타입과 무관하게 brace 블록 안에
`polygon`을 씁니다. 정점은 **최소 3개**.

```robotdsl
polygon (x, y) (x, y) (x, y) ...
```

### 7.2 존 타입과 추가 절

| 존 타입 | 추가 절 | 예 |
|---|---|---|
| `blocked` | — | `zone "x" blocked { polygon ... }` |
| `line_guided` | — | `zone "x" line_guided { polygon ... }` |
| `release` | — | `zone "x" release { polygon ... }` |
| `coordinated_replanning` | — | `zone "x" coordinated_replanning { polygon ... }` |
| `speed_limit` | `<속도>` | `zone "x" speed_limit 0.25 { polygon ... }` |
| `action` | `entry`/`during`/`exit` | 아래 참조 |
| `priority` | `factor <0.0~1.0>` | `zone "x" priority factor 0.8 { polygon ... }` |
| `penalty` | `factor <0.0~1.0>` | `zone "x" penalty factor 0.9 { polygon ... }` |
| `directed` | `heading <rad>` `strictness ...` | `zone "x" directed heading 0.0 strictness restricted { polygon ... }` |
| `bidirected` | `heading <rad>` `strictness ...` | `zone "x" bidirected heading 1.5708 strictness soft { polygon ... }` |

`strictness` 값:

- `directed`: `soft` · `restricted` · `strict`
- `bidirected`: `soft` · `restricted` (STRICT 없음)

### 7.3 액션 존

액션 존은 폴리곤과 **함께** 세 개의 액션 그룹을 씁니다. 셋 다 스키마가 요구하므로,
비어 있어도 그룹은 반드시 적습니다.

```robotdsl
zone "hazard-entry" describe "위험 구역 진입 시 경보" action {
  entry   { action "beaconOn" describe "경보 시작" }
  during  { action "beaconOn" }
  exit    { action "beaconOff" }
  polygon (28, 0) (34, 0) (34, 6) (28, 6)
}
```

빈 그룹은 `during { }`처럼 씁니다.

### 7.4 존 타입을 고르는 요령

| 원하는 것 | 존 타입 |
|---|---|
| 절대 못 지나간다 | `blocked` |
| 표시된 선을 따라간다 | `line_guided` |
| 관제의 명시적 해제 필요 | `release` |
| 로봇끼리 서로 우회해서 재계획 | `coordinated_replanning` |
| 여기선 느리게 | `speed_limit <값>` |
| 지나가면서 뭔가 한다 | `action` |
| 이 길을 선호한다 | `priority factor <값>` |
| 가능하면 피한다 | `penalty factor <값>` |
| 이 방향으로만 | `directed heading <rad>` |
| 이 방향과 그 반대만 | `bidirected heading <rad>` |

`priority`와 `penalty`는 반대 개념입니다. `factor 1.0`은 최대, `0.0`은 존이 없는
것과 같습니다.

---

## 8. 전체 문법 한눈에 보기

```
파일      := { 헤더선언 | 메시지 }

헤더선언  := robot <문자열> <문자열>
           | map <문자열>
           | version <정수>.<정수>.<정수>
           | header <정수>
           | timestamp <문자열>

메시지    := zoneset <문자열> [on map <문자열>] [describe <문자열>] { { 존 } }
           | order <문자열> [update <정수>] [describe <문자열>] { 주문본문 }
           | instant <문자열>? { { 액션 } }

존        := zone <문자열> [describe <문자열>] 존타입 { 폴리곤 | 액션그룹 }

주문본문  := { 세그먼트 | 스텝 }
세그먼트  := (route | base) { { 스텝 } }
           | horizon { { 스텝 } }
스텝      := node <문자열> { 노드수식어 } [ { { 액션 } } ]
           | edge <문자열>? { 엣지수식어 } [ { { 액션 } } ]
           | go to <문자열> { 노드수식어 | 엣지수식어 | via <문자열> } [ { { 액션 } } ]

액션그룹  := (entry | during | exit) { { 액션 } }
폴리곤    := polygon ( <숫자> , <숫자> ) { ( <숫자> , <숫자> ) }

액션      := action <문자열> { 액션수식어 }
액션수식어:= blocking (none | soft | single | hard)
           | describe <문자열>
           | retriable
           | with { [ <이름> = 값 ] , ... }
```

---

## 9. 자주 쓰는 패턴

### 9.1 픽 앤 드롭

```robotdsl
robot "acme" "AMR-001"
map "plant-b"

order "order-pallet-1" update 0 describe "KLT 팔레타이징" {
  base {
    node "RK-AM" describe "랙 통로 표지" at (12.5, 3.0) facing 0.0 {
      action "pick" blocking HARD describe "팔레트 집기" with {
        loadId = "KLT-42"
        loadType = "EPAL"
      }
    }
    edge "e-1" describe "메인 복도" speed 0.8 length 14.2
    node "CHG-01" describe "컨베이어 A 하적점" at (0.0, 0.0) facing 1.5708 {
      action "drop" blocking HARD with { loadId = "KLT-42" }
    }
  }
}
```

### 9.2 충전 후 복귀

```robotdsl
robot "acme" "AMR-001"
map "plant-b"

order "order-charge" {
  base {
    node "CHG-01" at (0.0, 0.0) {
      action "charge" blocking HARD with { duration = 600 }
    }
    go to "ST-07" at (7.0, 1.0)
  }
}
```

### 9.3 순찰 (같은 노드 재방문)

`nodeId`는 한 주문 안에서 중복돼도 됩니다. `sequenceId`가 순서를 구분합니다.

```robotdsl
order "order-patrol" {
  base {
    node "P1" at (0, 0)   { action "initPosition" }
    go to "P2" at (10, 0) { action "inspect" with { duration = 30 } }
    go to "P3" at (10, 10){ action "inspect" with { duration = 30 } }
    go to "P1" at (0, 0)
  }
}
```

### 9.4 보행자 구역 속도 제한

```robotdsl
zoneset "zs-floor1" on map "plant-b" {
  zone "pedestrian-zone" describe "보행자 통행 구간" speed_limit 0.25 {
    polygon (20, 0) (26, 0) (26, 6) (20, 6)
  }
}
```

### 9.5 정지 / 재개 / 중단 세 버튼

```robotdsl
instant "pause-fleet" {
  action "startPause"
  action "stateRequest"
}

instant "resume" {
  action "stopPause"
}

instant "abort" {
  action "cancelOrder" describe "운영자 중단"
}
```

### 9.6 한 파일에 전부 넣기

한 `.robot` 파일에 zoneset, order, instant을 섞어 쓸 수 있습니다. 선언 순서대로
메시지가 나오고, 파일도 그 순서로 생성됩니다.

```robotdsl
robot "acme" "AMR-001"
map "plant-b"

zoneset "zs-floor1" on map "plant-b" { ... }
order "order-pallet-1" { ... }
instant "정지" { ... }
```

---

## 10. 컴파일하고 확인하기

`robotdsl`은 `cabal build`만으로는 `PATH`에 올라가지 않습니다. 두 가지 방법이
있습니다.

**방법 A — 프로젝트 안에서 (설치 불필요)**

```bash
cabal run -v0 robotdsl -- check my.robot
```

**방법 B — 한 번 설치해서 어디서든**

```bash
cabal install exe:robotdsl --installdir ~/.local/bin --overwrite-policy=always
robotdsl check my.robot
```

> **주의 1: 디렉터리 이름은 `examples` (복수)입니다.** `example`이 아닙니다.
> 오타면 `cannot read './example/control.robot': no such file, or not readable`
> 가 나옵니다.

> **주의 2: `compile`은 스키마를 현재 디렉터리 기준으로 찾습니다.**
> `schemas/vda5050/3.0.0`를 상대 경로로 보므로, 프로젝트 루트에서 실행하거나
> `--schema-dir`로 절대 경로를 주세요. `check`는 스키마가 필요 없어 어디서든
> 동작합니다.

검증은 세 단계이고, **셋 다 통과해야만 파일이 써집니다**.

1. **파싱** — 모양. 줄·열 번호가 오류에 나옵니다.
2. **의미 검사** — 틀리기 쉬운 규칙(즉시액션 blockingType, 폴리곤 정점 수,
   노드-엣지 교대, mapId 해석 가능 여부).
3. **스키마 검사** — 공식 v3.0.0 JSON Schema 대조.

파일을 저장할 때 각 메시지의 MQTT 토픽이 같이 찍힙니다.

```
out/order-pallet-1.order.json  (vda5050/v3/acme/AMR-001/order)
```

독립 교차 검증(선택):

```bash
python3 tools/verify-output.py out/     # 274건 검사
```

---

## 11. 오류 메시지 해설

### 파싱 오류

```
error: my.robot:4:31:
   |
4 |   zone "too-fast" speed_limit {
  |                               ^
unexpected '{'
expecting a speed in m/s
```

`speed_limit`은 반드시 속도값을 받습니다. `speed_limit 0.25`처럼 고치세요.

```
error: my.robot:6:1:
   |
6 | <empty line>
  | ^
unexpected end of input
expecting '}' or a name or keyword
```

**닫는 중괄호가 빠졌습니다.** 메시지가 파일 끝(EOF)을 가리키면 열린 블록을 어디서
닫아야 하는지 세어 보세요. `order`·`zoneset`·`node`·`edge`·`action`·`with`·`polygon`
블록이 각각 짝을 이루는지 확인하세요.

```
error: my.robot:1:7:
   |
1 | robot acme "AMR-001"
  |       ^
unexpected 'a'
expecting '"'
```

**이름의 따옴표가 빠졌습니다.** 이름은 항상 따옴표로 감싸야 합니다.
`robot "acme" "AMR-001"`처럼 고치세요. 화살표가 가리키는 글자가 따옴표 없는
이름의 첫 글자입니다.

### 의미 오류
```
instant action 'startPause': blockingType must be NONE in VDA 5050 v3.0.0: ...
Got HARD, which is only valid on order actions.
```

`instant` 블록에서 `blocking HARD`를 지우세요. 즉시액션은 항상 이동과 병렬
실행되므로 v3.0.0 스키마의 enum이 `NONE`뿐입니다.

```
order 'o1' step 0: an order must start with a node, not an edge; the first step is edge 'e1'
```

주문은 반드시 노드로 시작해야 합니다. 앞에 `node`를 하나 두세요.

```
order 'o1' step 2: steps must alternate node, edge, node, ...; this edge 'e5' follows another edge 'e4'
```

엣지가 연달아 나왔습니다. 노드와 엣지를 번갈아 배치하세요. 연속된 엣지가
필요하면 `go to`를 나눠 쓰거나, 중간에 경유 노드를 두세요.

```
zoneSet 'zs' zone 'thin': a zone polygon needs at least 3 vertices, got 2
```

폴리곤 정점이 3개 미만입니다.

```
order 'o1' node 'n1': this node has a position but no mapId; add `map <id>` ...
```

위치가 있는 노드인데 맵을 특정할 수 없습니다. 파일 위에 `map "plant-b"`를
넣거나 노드에 `on map "plant-b"`를 붙이세요.

```
zoneSet 'z': this zoneSet has no mapId; add `map <id>` ... or `on map <id>` on the zoneset
```

zoneset도 맵에 속합니다. 파일 위에 `map "plant-b"`를 넣거나
`zoneset "z" on map "plant-b"`처럼 쓰세요.

```
order 'o1': orderUpdateId must be a non-negative integer, got -1.0
```

`update -1`처럼 음수를 줬습니다. 새 주문이면 `update 0`이거나 아예 생략하세요.

```
program: no robot declared; add `robot <manufacturer> <serialNumber>` or pass
--manufacturer and --serial-number
```

메시지의 수신자가 정해지지 않았습니다. 파일에 `robot` 줄을 넣거나 CLI 플래그를
주세요.

```
program: no messages declared; expected at least one order, instantActions or zoneset
```

파일에 헤더 선언만 있고 실제 메시지가 없습니다.

### 스키마 오류

의미 검사가 대부분의 규칙을 더 좋은 메시지로 먼저 잡아내기 때문에, 스키마
단계까지 도달하는 경우는 드뭅니다. 예를 들어 `theta` 범위 초과나 폴리곤 정점
부족은 의미 검사 단계에서 이미 잡힙니다.

스키마 단계는 **최종 방어선**입니다. 메시지가 어떤 이유로든 표준에 어긋나면
여기서 잡히고, 아무 파일도 쓰이지 않습니다.

```
o1: /orderUpdateId: minimum violated: -1.0 vs limit 0.0
```

(`orderUpdateId` 음수는 의미 검사에서도 잡히므로, 실제로는 이 메시지 대신
`order 'o1': orderUpdateId must be a non-negative integer, got -1.0`이
나옵니다.)

메시지 경로가 `/nodes/0/nodePosition/theta`처럼 JSON 포인터로 나오면, 그 위치의
값이 스키마 조건을 어겼다는 뜻입니다.

---

## 12. 작성 요령

**헤더는 파일마다 한 번.** `robot`과 `map`을 파일 위에 한 번 써두면 이후 모든
노드가 물려받습니다.

**`go`를 기본으로, `edge`는 세밀한 제어가 필요할 때.** 대부분의 경로는
`go to "X" at (a, b)`면 충분합니다. 엣지에 `corridor`이나 `trajectory`를 걸
때만 명시적 `edge`를 쓰세요.

**액션 이름은 표준 것을 쓰세요.** `actionType`은 VDA 5050의 "Actions and
Parameters" 표에 정의된 이름(`pick`, `drop`, `charge`, `initPosition`,
`startPause`, `cancelOrder`, `stateRequest`, ...)을 써야 로봇이 이해합니다.
임의의 문자열을 넣으면 스키마는 통과하지만 로봇이 거부합니다.

**`describe`는 사람을 위한 것입니다.** 논리 처리는 `actionDescriptor`,
`nodeDescriptor`, `edgeDescriptor`, `orderDescription`, `zoneDescriptor`를
사용하지 말고, 반드시 `with { ... }` 파라미터로 넘기세요.

**`blocking`은 필요한 곳에만.** 기본값이 이미 맞습니다. 즉시액션에는 절대
쓰지 마세요(오류).

**`base`는 짧게, `horizon`은 길게.** `base`는 이미 실행을 허락한 구간이고,
`horizon`은 미래 계획입니다. 실무에서는 가까운 몇 개 노드만 `base`에 두고
나머지는 `horizon`에 두는 경우가 많습니다.

**`update`는 주문을 고칠 때만.** 같은 `orderId`로 다시 보내 갱신할 때
`update <N>`을 1씩 올립니다. 새 주문이면 `update 0`이거나 아예 생략.

**존은 지도를 대체하지 않습니다.** 존은 내비게이션 제약입니다. 지나갈 수 없는
물리적 장애물은 지도에 넣고, 존은 규칙(속도, 방향, 선호도, 해제)에 쓰세요.

**파일은 버전 관리하세요.** `actionId`와 `edgeId`가 결정론적이므로 소스가 같으면
출력이 항상 같습니다. diff가 의미 있습니다.

---

## 더 보기

- 전체 문법 레퍼런스와 CLI 플래그: [`README.md`](../README.md)
- 동작하는 예제 세 개: [`../examples/`](../examples/)
- `robotdsl --help`
