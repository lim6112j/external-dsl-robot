# Phase 2 Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the agent turn a validated `.robot` order into the fleet gateway's `OrderRequest` and publish it, with dry-run and rejection rules between the operator and the robot.

**Architecture:** Add a JSON POST helper to the existing read-only `Fleet` client, a new `Dispatch` module that owns the AST → `OrderRequest` conversion and all pre-publish guards, and two agent HTTP routes (`POST /api/dispatch`, `POST /api/instant-actions`). No browser UI in this plan: the routes are the trigger, callable with `curl`. The model stays a translator; only DSL that parses, validates and passes the map guards can be published.

**Tech Stack:** GHC 9.10 / cabal, `aeson`, `wai`/`warp`, `http-client`, tasty + `testWithApplication` stub gateways.

**Spec:** `.stepcode/plans/session-01a1d304-334c-7400-868a-ef4049753a95.md`, `Phase 2 미리보기` (verbatim):

> - `Dispatch.hs` — 오더를 게이트웨이의 경로 형태로 재구성해 `POST /api/orders`로 보냅니다.
> - 거부 규칙 — 엣지 액션 · 엣지 제약 · zoneSet · 맵에 없는 노드/홉 · 노드 0개.
> - 안전장치 — 로봇 존재 확인(게이트웨이는 로봇을 검증하지 않고 주어진 토픽에 그대로 발행하므로 오타가 조용히 실패합니다), orderId 중복 거부, dry-run 기본 ON.
> - 즉시 액션 — `POST /api/robots/{robot_id}/instant-actions`.

**Scope decision (builder's call):** no browser button. The user explicitly dropped it; a later plan can wire the same routes into `web/app.js`. Real publishing additionally requires the agent to start with `--allow-dispatch`; without it every dispatch is a dry run. This is an extra guard on top of dry-run default ON, because the agent has no authentication.

## Global Constraints

- Target standard: VDA 5050 v3.0.0 (`protocolVersion` in `RobotDSL.Version`).
- Gateway contract (`로봇관제시스템/crates/gateway/src/api.rs`, `orders.rs`): `POST /api/orders` takes `{"manufacturer","serialNumber","orderId","orderUpdateId"?,"orderDescription"?,"nodes":[{"nodeId","actions":[{"actionType","actionId"?,"durationS"?,"blockingType"?,"parameters"?}],"released"?}]}`; the gateway derives `headerId`, edges and geometry and returns `{"status":"published","robotId","orderId","headerId","waypoints"}` or HTTP 400 `{"error","reasons"}`.
- Gateway robot identity is `manufacturer:serialNumber`; `POST /api/robots/{robot_id}/instant-actions` takes `{"actions":[{"actionType","actionId"?,"parameters"?}]}`.
- The gateway auto-numbers missing `actionId`s (`a1`, `a2`, …) and checks duplicates, so the agent must omit `actionId` rather than invent one.
- Existing routes answer HTTP 200 with `{"ok":false,"errors":[...]}` on rejection; keep that convention.
- Tests never touch a real gateway, MQTT broker or OpenRouter; use `testWithApplication` stubs. The test suite needs `-threaded` (already configured).
- Do not change Phase 1 behaviour: normal `command`/`compile`/`save` calls must never POST to the gateway. The existing AgentSpec test "the agent never writes to the fleet gateway" stays green.

## Review Focus

| Input / condition | Expected behaviour | Test owner |
|---|---|---|
| DSL robot differs from the selected robot | reject before any POST, naming both identities | Task 2 |
| Gateway answers 400 to `POST /api/orders` | readable `errors`, and the order id is **not** remembered as sent | Task 3 |
| Same `orderId` dispatched twice | second attempt rejected, no POST | Task 3 |
| DSL has zones, edge constraints/actions, unplaced hops, or two orders | reject with the preview's exact reasons, no POST | Task 2 |
| Gateway is unreachable / returns no online robot | fail closed with a readable error; never publish to an unchecked id | Task 3 |
| `dryRun` omitted or true / `--allow-dispatch` absent | return the would-be request, POST nothing; response says dry run | Tasks 3, 4 |

---

### Task 1: JSON POST in the fleet client

**Files:**
- Modify: `agent-src/RobotDSL/Agent/Fleet.hs` (export list, add `postJson`, generalize `issue`)
- Test: `test/FleetSpec.hs`

**Interfaces:**
- Consumes: existing `FleetConfig`, `getJson` error format.
- Produces: `postJson :: Manager -> FleetConfig -> Text -> Value -> IO (Either String Value)` — POSTs one JSON body to `fcBaseUrl ++ path`, sends `Authorization: Bearer` when `fcToken` is set, returns decoded JSON or a readable `String` reason including status and response body (clipped to 400 chars).

- [ ] **Step 1: Write failing tests in `test/FleetSpec.hs`**

Extend the stub so `["api","orders"]` records `(method, body, Authorization)` in a new `IORef` and answers `status200` with `{"status":"published"}`. Add:
  - `postJson` reaches `/api/orders` with method `POST`, the exact body sent, and `Content-Type: application/json`;
  - a configured token produces `Bearer s3cret` on POST too;
  - `withGatewayAt status400` yields a `Left` whose reason contains "400" and the response body.
  - the existing seven fleet reads still pass unchanged.

- [ ] **Step 2: Run the tests and verify they fail to compile**

Run: `cabal test -v0 2>&1 | tail -20`
Expected: FAIL — `Variable not in scope: postJson`.

- [ ] **Step 3: Implement `postJson` in `agent-src/RobotDSL/Agent/Fleet.hs`**

Refactor `issue` into a helper taking method and optional body; keep `getJson` delegating to it with no body. Set `hContentType = application/json` and `setRequestBodyLBS (encode body)` for POST. Reuse the current non-200 / decode failure messages.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cabal test -v0 2>&1 | tail -20`
Expected: all tests PASS, including the seven pre-existing fleet tests.

- [ ] **Step 5: Commit**

```bash
git add agent-src/RobotDSL/Agent/Fleet.hs test/FleetSpec.hs
git commit -m "feat: add authenticated JSON POST to the fleet client"
```

---

### Task 2: Pure dispatch plan and rejection rules

**Files:**
- Create: `agent-src/RobotDSL/Agent/Dispatch.hs`
- Create: `test/DispatchSpec.hs`
- Modify: `test/Spec.hs`, `robotdsl.cabal` (agent `exposed-modules`, test `other-modules`)

**Interfaces:**
- Consumes: `Loop.inject :: LoopConfig -> Program -> Program`, `Loop.finalize`, `Preview.preview`, `Fleet.RobotRef`, `AST.Program/Order/Step/Node/Action/BlockingType/ActionValue`, `Emit.EmitContext`.
- Produces:
  ```haskell
  data DispatchOutcome = DispatchOutcome
    { doRequest  :: !Value       -- the exact OrderRequest JSON
    , doOrderId  :: !Text
    } deriving (Eq, Show)

  planOrder :: Vocabulary -> LoopConfig -> RobotRef -> Text -> Either [Text] DispatchOutcome
  actionValueJSON :: ActionValue -> Value     -- exported for direct tests
  ```
  `planOrder` is pure: parse → inject → validate via the same path as `Loop.finalize` (refactor `Loop` minimally so both call one `parseValidate :: LoopConfig -> Text -> Either [Text] Program`; `finalize` keeps its existing exported type and behaviour), then check the guards below, then build the request.

- [ ] **Step 1: Write failing tests in the new `test/DispatchSpec.hs`**

Build a `LoopConfig` the way `AgentSpec` does (manager from `newManager defaultManagerSettings`, `ClientConfig` with dummy key, `Vocabulary` naming the two map nodes, `EmitContext` for `acme`/`AMR-001`). Use a helper DSL like:

```robotdsl
robot "acme" "AMR-001"
order "order-test" update 3 describe "test run" {
  base {
    node "RK-AM" { action "pick" blocking HARD with { loadId = "KLT-42", n = 2, ok = true } }
    edge "e-1"
    node "CHG-01" { action "drop" }
  }
  horizon { node "ST-07" }
}
```

with a vocabulary that knows all three nodes and the hops `RK-AM -> CHG-01`, `CHG-01 -> ST-07`. Assert:
  - `doRequest` has `manufacturer = acme`, `serialNumber = AMR-001`, `orderId = order-test`, `orderUpdateId = 3`, `orderDescription = test run`;
  - `nodes` has exactly three waypoints in travel order, edge steps skipped, with `nodeId`, `released = [true,true,false]` and actions carrying `actionType`, `blockingType = "HARD"`/`"HARD"`/`"NONE"`, and `parameters = {"loadId":"KLT-42","n":2,"ok":true}`; no `actionId` key anywhere;
  - an action with `blocking SOFT` maps to `"SOFT"` (and `SINGLE`/`NONE` likewise via `blockingTypeJSON`, tested through DSL);
  - `actionValueJSON (AVArray [AVString "x", AVBool False])` is the expected JSON array;
  - the selected robot's identity is used even when the DSL omits `robot`, and a DSL naming a different serial is rejected with both identities in the reason;
  - a DSL with a zone set is rejected; a DSL with an edge constraint or edge action is rejected; a DSL with an unplaced node or hop is rejected; a DSL with no order and an order with no nodes are rejected; a DSL with two orders is rejected; invalid DSL is rejected by the parser/validator path.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cabal test -v0 2>&1 | tail -20`
Expected: FAIL — missing `RobotDSL.Agent.Dispatch` / `DispatchSpec`.

- [ ] **Step 3: Implement `planOrder` in `agent-src/RobotDSL/Agent/Dispatch.hs`**

Conversion: `concatMap segSteps (ordSegments o)`, keep only `StepNode`; `released = segReleased`; omit `actionId`; `blockingType` uppercase via a total `BlockingType -> Text` mapping; `parameters` from `actParameters`, omitted when empty. Guards, returning all reasons at once where practical: parse/validate errors, `preview voc prog` `Left`, `pvUnplaced`, `pvWarnings`, `length declOrders /= 1`, no waypoints, identity mismatch. Compare the injected `progRobot` against `(rrManufacturer robot, rrSerialNumber robot)`.

- [ ] **Step 4: Refactor `Loop.finalize` to share `parseValidate`**

Add `parseValidate :: LoopConfig -> Text -> Either [Text] Program` to `Loop`'s export list and make `finalize` use it. All existing `Loop`/`AgentSpec` tests must keep passing unchanged.

- [ ] **Step 5: Wire the new module and test into `robotdsl.cabal` and `test/Spec.hs`**

Add `RobotDSL.Agent.Dispatch` to the agent library's `exposed-modules`, `DispatchSpec` to the test suite's `other-modules` and to `Spec.hs`'s group list.

- [ ] **Step 6: Run the tests and verify they pass**

Run: `cabal test -v0 2>&1 | tail -20`
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add agent-src/RobotDSL/Agent/Dispatch.hs agent-src/RobotDSL/Agent/Loop.hs test/DispatchSpec.hs test/Spec.hs robotdsl.cabal
git commit -m "feat: plan gateway orders from validated DSL, with dispatch guards"
```

---

### Task 3: Dispatch IO — robot check, duplicates, dry run, publish

**Files:**
- Modify: `agent-src/RobotDSL/Agent/Dispatch.hs`
- Test: `test/DispatchSpec.hs`

(`dcSeenOrders` is supplied by the caller; the `AppState` fields that hold it are added in Task 4.)

**Interfaces:**
- Consumes: `Fleet.fetchRobots`, `Fleet.postJson`, `planOrder`.
- Produces:
  ```haskell
  data DispatchConfig = DispatchConfig
    { dcLoop         :: !LoopConfig
    , dcFleet        :: !FleetConfig
    , dcRobot        :: !RobotRef
    , dcAllowPublish :: !Bool
    , dcSeenOrders   :: !(IORef [Text])
    }

  dispatchOrder :: DispatchConfig -> Text -> Bool -> IO (Either [Text] (Value, Bool))
  -- Right (responseValue, wasDryRun). dryRun=True never POSTs.
  -- dcAllowPublish=False forces dry run regardless of the Bool argument.
  ```

- [ ] **Step 1: Write failing tests in `test/DispatchSpec.hs`**

Against a stub gateway (`testWithApplication`) that records POSTs and can be told to return 400:
  - dry run: `Right (resp, True)`, request echoed in `resp`, zero POSTs;
  - `dcAllowPublish = False` with `dryRun = False`: still `Right (_, True)`, zero POSTs;
  - happy publish: exactly one POST to `/api/orders`, body equals the planned request, `resp` contains gateway's `status`, and the id is added to `dcSeenOrders`;
  - second publish of the same DSL: `Left` mentioning duplicate `orderId`, POST count unchanged;
  - gateway 400: `Left` containing the gateway reason, POST count 1, `dcSeenOrders` still empty;
  - robot gone from `/api/robots`, robot offline, and gateway unreachable: each `Left` with a readable reason and zero POSTs;
  - a DSL that `planOrder` rejects: zero POSTs.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cabal test -v0 2>&1 | tail -20` — expected FAIL (`dispatchOrder` not defined).

- [ ] **Step 3: Implement `dispatchOrder`**

Order of operations: `planOrder` first (pure guards) → `fetchRobots` and require an online robot with `rrRobotId == dcRobot` → duplicate check against `dcSeenOrders` → if dry run or not allowed, return the request with `True` and no write → else `postJson` to `/api/orders`; on success append the id to `dcSeenOrders`, on failure return the gateway's `reasons` verbatim.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cabal test -v0 2>&1 | tail -20` — expected all PASS.

- [ ] **Step 5: Commit**

```bash
git add agent-src/RobotDSL/Agent/Dispatch.hs test/DispatchSpec.hs
git commit -m "feat: dry-run-first dispatch with robot and duplicate guards"
```

---

### Task 4: Agent HTTP route and startup flag

**Files:**
- Modify: `agent-src/RobotDSL/Agent/Server.hs`, `app/AgentMain.hs`, `test/AgentSpec.hs`
- Modify: `README.md` (document `--allow-dispatch`, the route and its payload)

**Interfaces:**
- Consumes: `dispatchOrder`, `DispatchConfig`.
- Produces: `POST /api/dispatch` with body `{"dsl": Text, "robotId": Text, "dryRun": Bool?}` (dry run defaults to `True`); answers `{"ok":true,"dryRun":Bool,"request":Value,"gateway":Value?}` or `{"ok":false,"errors":[Text]}`.
  `AppState` gains `asDispatchAllow :: !Bool` and `asSeenOrders :: !(IORef [Text])`; `newAppState` gains a leading `Bool` argument.

- [ ] **Step 1: Write failing tests in `test/AgentSpec.hs`**

Using the existing nested-`testWithApplication` pattern (`serverAppWith` / gateway recorder):
  - omitting `dryRun` produces a dry run and no gateway POST;
  - `{"dryRun":false}` with a recorder gateway produces one POST to `/api/orders` and the gateway response in `gateway`;
  - a missing/unknown `robotId` is rejected without a POST;
  - a rejected DSL (`zone` block) is rejected without a POST;
  - with `newAppState False ...` (no `--allow-dispatch`), `{"dryRun":false}` still produces no POST;
  - the pre-existing test "the agent never writes to the fleet gateway" still passes (it does not call `/api/dispatch`).

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cabal test -v0 2>&1 | tail -20` — expected FAIL (route 404 / signature mismatch).

- [ ] **Step 3: Implement the route and flag**

Add `asDispatchAllow` / `asSeenOrders` to `AppState` and `newAppState`; add `("POST", ["api","dispatch"]) -> handleDispatch`; implement `handleDispatch` using `refreshVocab`, `resolveRobot` (fail closed when `Nothing`), `loopConfigWith st fresh Nothing`, and `dispatchOrder`. Add `optAllowDispatch :: !Bool` to `AgentMain.Options`, parse `--allow-dispatch`, pass it to `newAppState`, and log it next to the other startup lines plus a line in `usage`.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cabal test -v0 2>&1 | tail -20` — expected all PASS.

- [ ] **Step 5: Commit**

```bash
git add agent-src/RobotDSL/Agent/Server.hs app/AgentMain.hs test/AgentSpec.hs README.md
git commit -m "feat: add POST /api/dispatch with dry-run default"
```

---

### Task 5: Instant actions route

**Files:**
- Modify: `agent-src/RobotDSL/Agent/Dispatch.hs`, `agent-src/RobotDSL/Agent/Server.hs`, `test/DispatchSpec.hs`, `test/AgentSpec.hs`

**Interfaces:**
- Produces:
  ```haskell
  sendInstant :: DispatchConfig -> [Text] -> Bool -> IO (Either [Text] (Value, Bool))
  -- POST /api/robots/{robotId}/instant-actions with {"actions":[{"actionType":t}]}
  ```
  Agent route: `POST /api/instant-actions` body `{"robotId": Text, "actions": [Text], "dryRun": Bool?}`; same response shape as `/api/dispatch`. Reject an empty action list. Same dry-run / `--allow-dispatch` / robot-exists rules as orders. No duplicate-id guard (the gateway numbers instant actions itself).

- [ ] **Step 1: Write failing tests**

In `DispatchSpec`: dry run → no POST; with `dcAllowPublish = True` → one POST to `/api/robots/acme:AMR-001/instant-actions` with the expected body; empty action list → `Left`, no POST. In `AgentSpec`: the route defaults to dry run and rejects an unknown robot without a POST.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cabal test -v0 2>&1 | tail -20` — expected FAIL (`sendInstant` not defined).

- [ ] **Step 3: Implement `sendInstant` and the route**

Reuse the robot check from Task 3; URL-escape nothing (gateway robot ids are `manufacturer:serialNumber`, safe in a path segment). Answer with the gateway JSON on success.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cabal test -v0 2>&1 | tail -20` — expected all PASS.

- [ ] **Step 5: Commit**

```bash
git add agent-src/RobotDSL/Agent/Dispatch.hs agent-src/RobotDSL/Agent/Server.hs test/DispatchSpec.hs test/AgentSpec.hs
git commit -m "feat: add instant-action dispatch route"
```

---

### Task 6: Documentation and final verification

**Files:**
- Modify: `README.md`, `web/app.js` (only the stale header comment), `docs/DSL-GUIDE.md` if it describes the agent as incapable of publishing.

- [ ] **Step 1: Update the docs**

In the README's AI-agent section: state that the model is still only a translator, that **publishing happens only via `POST /api/dispatch` (or `/api/instant-actions`) with `"dryRun":false` and the agent started with `--allow-dispatch`**, and show one `curl` example for a dry run and one for a real dispatch. Add both routes to the route table and `--allow-dispatch` to the flags section. Update the stated test count to the actual final count. In `web/app.js`, replace the Phase-1-only comment with a note that dispatch is now an API route.

- [ ] **Step 2: Full verification**

Run: `cabal build -v0 && cabal test -v0 2>&1 | tail -30`
Expected: build succeeds; all tests pass; the final count is reported.

- [ ] **Step 3: Commit**

```bash
git add README.md web/app.js docs/DSL-GUIDE.md
git commit -m "docs: document phase 2 dispatch routes and safety gates"
```
