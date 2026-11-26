# Design: browser dispatch button (two-step confirm)

**Intent:** an operator who generated and checked a mission in the browser can publish it without switching to curl. The button sits next to `저장` and reuses the existing `POST /api/dispatch`; no new backend write path is introduced.

**Goals**
- First click makes a dry run and shows the exact `OrderRequest` on screen.
- Second, explicit click publishes (`"dryRun":false`).
- Editing the DSL or changing the selected robot after a dry run invalidates the pending confirmation.
- The UI tells the operator when the agent was started without `--allow-dispatch` (publishing impossible).

**Non-goals / anti-goals**
- No instant-action UI, no MQTT publishing from the browser, no new dispatch API.
- The button must never publish an unreviewed DSL: the server still parses, validates, checks the map, checks the robot and rejects duplicates.

**Constraints**
- Existing server contract: `POST /api/dispatch` body `{dsl, robotId, dryRun?}`; dry run defaults to `True`; response `{ok, dryRun, request, gateway?}` or `{ok:false, errors}`.
- `GET /api/context` currently does not expose `asDispatchAllow`, so the UI cannot know whether publishing is enabled; add one field.
- The page is plain HTML/CSS/JS with no build step (`web/`); follow its existing event-wiring and status-panel patterns.
- `--fleet` is required for any dispatch; with only `--map` the server rejects with a readable reason.

**Approaches**
- **A (chosen): two-step confirm.** Click `실제 투입` → dry run → show `request` JSON and a confirm bar with `확인 투입` / `취소` → confirm publishes. Safest and matches the server's dry-run-first design. Cost: one extra click and a small amount of UI state.
- **B (rejected): one click plus `window.confirm`.** Less UI code, but the operator confirms a dialog rather than the actual request body, and a reflex click publishes to hardware.

**Design**
1. `web/index.html`: add `dispatch` button after `save`, plus a hidden confirm bar (`dispatch-confirm` with `dispatch-go`, `dispatch-cancel`) and a `<pre id="dispatch-preview">` panel in the existing results area.
2. `web/app.js`: `dispatch()` posts `{dsl, robotId, dryRun:true}`, renders the returned `request`, reveals the confirm bar; `dispatchGo()` repeats with `dryRun:false` and shows the gateway result; `dispatchCancel()` hides the bar. Store the previewed DSL and robot id and clear the pending state whenever the textarea or robot selection changes.
3. `GET /api/context` gains `"dispatchAllowed": asDispatchAllow st`; `loadContext()` disables the button and explains why when false.
4. Errors from any step go through the existing `showErrors` / `setStatus` helpers, so failed dry runs and failed publishes look like existing compile failures.

**Left to the implementer:** exact DOM ids, CSS class names, and the browser-test fixture; none of these change the behaviour above.
