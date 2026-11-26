# Dispatch Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** add a two-step "실제 투입" button next to `저장` so an operator can dry-run and then publish the validated DSL from the browser.

**Architecture:** reuse the existing `POST /api/dispatch` unchanged. The page adds one button plus a hidden confirm bar and a preview panel; the first click posts a dry run and renders `request`, the second posts `dryRun:false`. `GET /api/context` gains one boolean so the page can explain when publishing is disabled. Browser checks intercept the dispatch route, so no test publishes to a real gateway.

**Tech Stack:** plain HTML/CSS/JS in `web/`, Haskell wai server, Playwright (`tools/browser-test.js` pattern), tasty for the server test.

**Spec:** `docs/superpowers/specs/2026-11-26-dispatch-button-design.md`

## Global Constraints

- `POST /api/dispatch` request: `{dsl: Text, robotId: Text, dryRun?: Bool}`; dry run defaults to `True`; publishing additionally requires the agent to have been started with `--allow-dispatch`.
- `POST /api/dispatch` answers `{"ok":true,"dryRun":Bool,"request":Value,"gateway":Value?}` or `{"ok":false,"errors":[Text]}`; never assume `gateway` exists.
- No new backend write route, no MQTT from the browser, no build step for `web/`.
- The whole Haskell suite must stay green (`cabal test -v0`); browser checks are separate and must never publish to a real gateway.
- Editing `web/app.js` must not reintroduce the pre-existing duplicate `showWaste(null)` calls — do not touch that block.

## Review Focus

| Input / condition | Expected behaviour | Test owner |
|---|---|---|
| DSL edited after a dry run | confirm bar is cleared; a later confirm cannot publish the old route | Task 2 |
| No robot selected | button explains the need instead of sending a request with an empty id | Task 2 |
| `--allow-dispatch` absent | button disabled with a visible reason; no request is sent | Tasks 1, 2 |
| Dry run returns `ok:false` | errors shown, confirm bar never appears | Task 2 |
| Publish returns `ok:false` | errors shown, no success status | Task 2 |
| A user clicks confirm twice quickly | second click cannot send without a fresh dry run | Task 2 |

---

### Task 1: Tell the browser whether publishing is enabled

**Files:**
- Modify: `agent-src/RobotDSL/Agent/Server.hs`
- Test: `test/AgentSpec.hs`

**Interfaces:**
- Consumes: `AppState.asDispatchAllow :: Bool` (already present).
- Produces: `GET /api/context` includes `"dispatchAllowed" .= asDispatchAllow st`.

- [ ] **Step 1: Write the failing tests in `test/AgentSpec.hs`**

In the `server` test group:
  - with the default `withServer` (no allow flag), `GET /api/context` has `dispatchAllowed == Just False`;
  - with `serverAppWithAllow True Nothing ...` inside `testWithApplication`, it is `Just True`.
  Use the existing `boolField` helper.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cabal test -v0 2>&1 | tail -20`
Expected: FAIL — `dispatchAllowed` missing (`Nothing`).

- [ ] **Step 3: Add the field to `contextValue` in `agent-src/RobotDSL/Agent/Server.hs`**

One line next to `hasFleet`, with a comment explaining why the browser needs it.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cabal test -v0 2>&1 | tail -20` — expected all PASS.

- [ ] **Step 5: Commit**

```bash
git add agent-src/RobotDSL/Agent/Server.hs test/AgentSpec.hs
git commit -m "feat: expose dispatch availability in the agent context"
```

---

### Task 2: Two-step dispatch button in the browser

**Files:**
- Modify: `web/index.html`, `web/app.js`, `web/style.css`
- Create: `tools/browser-test-dispatch.js`

**Interfaces:**
- Consumes: `/api/context` `dispatchAllowed`, `state.selectedRobot`, `$("dsl").value`, `api()`, `setStatus()`, `showErrors()`.
- Produces: buttons `#dispatch`, `#dispatch-go`, `#dispatch-cancel`; panel `#dispatch-preview`; JS functions `dispatch()`, `dispatchGo()`, `dispatchCancel()`, `clearDispatchPending()`.

- [ ] **Step 1: Write the failing browser test `tools/browser-test-dispatch.js`**

Follow `tools/browser-test.js` (chromium launch, `check()` tally, exit code). Intercept `POST /api/dispatch` with `page.route`, record every body and answer with a hand-written `{"ok":true,"dryRun":true,"request":{"orderId":"order-test","nodes":[]}}` for dry runs and `{"ok":true,"dryRun":false,"request":{...},"gateway":{"status":"published","orderId":"order-test"}}` for publishes. Drive the real page and assert:
  - with `dispatchAllowed:false` forced via a `/api/context` route stub, `#dispatch` is disabled and has an explanatory `title`, and clicking changes nothing;
  - with `dispatchAllowed:true`, filling `#dsl` with a minimal order and clicking `#dispatch` sends exactly one body with `dryRun === true`, shows `order-test` in `#dispatch-preview`, and reveals `#dispatch-confirm`;
  - clicking `#dispatch-go` sends a second body with `dryRun === false` and shows `published` in `#status`;
  - after a dry run, editing `#dsl` hides `#dispatch-confirm`; a later `#dispatch-go` click sends nothing new;
  - with no robot selected, clicking `#dispatch` sends nothing and shows a Korean reason in `#status`;
  - a dry run answered `{"ok":false,"errors":["거부"]}` shows the reason and never reveals the confirm bar.
  The script starts against an already-running agent (`AGENT_PORT`, default 8790) just like the existing browser test; it does not need a real gateway because all dispatch calls are intercepted.

- [ ] **Step 2: Run the browser test and verify it fails**

Start a throwaway agent with a dummy key and a local map, then run the script:
```bash
OPENROUTER_API_KEY=dummy cabal run robotdsl-agent -- --port 8790 \
  --map /Users/nixos/workspace/로봇관제시스템/deploy/maps/plant-b.l1.json \
  --allow-dispatch &
node tools/browser-test-dispatch.js
```
Expected: FAIL — `#dispatch` does not exist.

- [ ] **Step 3: Implement the markup and styles**

In `web/index.html`, add `<button id="dispatch" title="실제 로봇에 임무를 보냅니다">실제 투입</button>` immediately after `#save`, and after the results panels add a hidden `<div id="dispatch-confirm" class="hidden">` with `#dispatch-go` ("확인 투입") and `#dispatch-cancel` ("취소") buttons plus a `<pre id="dispatch-preview">` for the dry-run body. Style only what the existing `hidden` / `row` / button classes do not already cover.

- [ ] **Step 4: Implement the JS flow**

In `web/app.js`:
```js
let dispatchPending = null; // { dsl, robotId }
async function dispatch() { /* dry run, render r.request, reveal bar */ }
async function dispatchGo() { /* publish with dryRun:false, show r.gateway */ }
function dispatchCancel() { /* hide bar, clear pending */ }
function clearDispatchPending() { /* same, called on dsl input and robot change */ }
```
Wire the three buttons. `dispatch()` must stop when `#dsl` is empty or `state.selectedRobot` is null, with a Korean `setStatus` message; `dispatchGo()` must stop when `dispatchPending` is null. Reuse `showErrors(r.errors)` and `setStatus` for every failure. Add a new `input` listener on `#dsl` (there is none today) that calls `clearDispatchPending()`, call it in `sendCommand()`/`recompile()` after replacing the DSL programmatically, and call it from the robot picker handler in `renderRobots()`. In `loadContext()`, disable `#dispatch` when `c.dispatchAllowed === false` and set its `title` to explain `--allow-dispatch`.

- [ ] **Step 5: Run the browser test and verify it passes**

Re-run the exact commands from Step 2. Expected: all checks pass and no intercepted publish happened during the dry-run checks.

- [ ] **Step 6: Run the Haskell suite and commit**

Run: `cabal test -v0` — expected all PASS (Task 1 behaviour preserved).
```bash
git add web/index.html web/app.js web/style.css tools/browser-test-dispatch.js
git commit -m "feat: add two-step dispatch button to the agent UI"
```

---

### Task 3: Documentation and final verification

**Files:**
- Modify: `README.md` (top workflow section and Dispatching a mission), `web/app.js` header comment.

- [ ] **Step 1: Update the docs**

In the top "임무 투입까지" section, replace the curl-only description with the two-step button flow and keep the curl example as the API reference. Note that publishing still needs `--allow-dispatch` and an online robot selected in the UI. Update the stale `web/app.js` comment that says dispatching is API-only.

- [ ] **Step 2: Full verification**

Run: `cabal build -v0 && cabal test -v0 2>&1 | tail -10` (expected all PASS), then re-run `node tools/browser-test-dispatch.js` against the throwaway agent (expected all PASS).

- [ ] **Step 3: Commit**

```bash
git add README.md web/app.js
git commit -m "docs: describe the browser dispatch button"
```
