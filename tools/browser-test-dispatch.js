#!/usr/bin/env node
// Browser checks for the two-step dispatch button.
//
// Every /api/dispatch call is intercepted: these checks exercise the real
// page and the real click flow, but never publish to a real gateway. Run with
// any agent serving web/ (a dummy OpenRouter key and --map are enough):
//
//   OPENROUTER_API_KEY=dummy cabal run robotdsl-agent -- --port 8790 --map <map>
//   node tools/browser-test-dispatch.js

const { chromium } = require("playwright");

const PORT = process.env.AGENT_PORT || "8790";
const BASE = `http://127.0.0.1:${PORT}`;

let passed = 0;
let failed = 0;
function check(name, ok, detail) {
  if (ok) {
    passed++;
    console.log(`  ok    ${name}${detail ? " — " + detail : ""}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name}${detail ? " — " + detail : ""}`);
  }
}

const ONLINE = [{
  robotId: "acme:AMR-001",
  manufacturer: "acme",
  serialNumber: "AMR-001",
  online: true,
  driving: false,
  orderId: "",
}];

const DSL = [
  'robot "acme" "AMR-001"',
  'order "order-test" {',
  '  base {',
  '    node "RK-AM" { action "pick" }',
  '    edge "e-1"',
  '    node "CHG-01" { action "drop" }',
  '  }',
  '}',
].join("\n");

let dispatchAllowed = true;
let robots = ONLINE;
let rejectDry = false;
const dispatched = [];

(async () => {
  const browser = await chromium.launch({ args: ["--no-sandbox"] });
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
  const consoleErrors = [];
  page.on("pageerror", (e) => consoleErrors.push(e.message));

  await page.route("**/api/context", (route) => route.fulfill({
    status: 200,
    contentType: "application/json",
    body: JSON.stringify({
      mapId: "plant-b",
      nodes: [{ id: "RK-AM", x: 1, y: 2 }, { id: "CHG-01", x: 3, y: 4 }],
      nodeIds: ["RK-AM", "CHG-01"],
      edges: [{ from: "RK-AM", to: "CHG-01" }],
      actions: [],
      robots,
      hasFleet: true,
      hasMap: true,
      model: "test",
      version: "3.0.0",
      sttReady: false,
      dispatchAllowed,
      manufacturer: "acme",
      serialNumber: "AMR-001",
    }),
  }));

  await page.route("**/api/dispatch", (route) => {
    const body = route.request().postDataJSON();
    dispatched.push(body);
    if (body.dryRun && rejectDry) {
      return route.fulfill({ status: 200, contentType: "application/json",
        body: JSON.stringify({ ok: false, errors: ["거부"] }) });
    }
    const request = { orderId: "order-test", nodes: [] };
    const answer = body.dryRun
      ? { ok: true, dryRun: true, request }
      : { ok: true, dryRun: false, request,
          gateway: { status: "published", orderId: "order-test", headerId: 1 } };
    return route.fulfill({ status: 200, contentType: "application/json",
      body: JSON.stringify(answer) });
  });

  console.log("\ndispatch button");
  await page.goto(BASE, { waitUntil: "networkidle" });

  dispatchAllowed = false;
  await page.reload({ waitUntil: "networkidle" });
  const disabled = await page.isDisabled("#dispatch");
  const title = await page.getAttribute("#dispatch", "title");
  await page.evaluate(() => document.querySelector("#dispatch").click());
  check("publishing disabled is visible", disabled && /allow-dispatch/.test(title || ""),
    `disabled=${disabled}, title=${title}`);
  check("disabled button sends nothing", dispatched.length === 0,
    `${dispatched.length} request(s)`);

  dispatchAllowed = true;
  await page.reload({ waitUntil: "networkidle" });
  await page.click("#robots button.robot:not([disabled])");
  await page.fill("#dsl", DSL);
  await page.click("#dispatch");
  await page.waitForSelector("#dispatch-confirm:not(.hidden)");
  check("first click only dry-runs", dispatched.length === 1 && dispatched[0].dryRun === true,
    JSON.stringify(dispatched[0]));
  check("the planned request is shown",
    /order-test/.test(await page.textContent("#dispatch-preview")));

  await page.click("#dispatch-go");
  // A reflex double-click must not produce a second publish attempt.
  await page.evaluate(() => document.querySelector("#dispatch-go").click());
  await page.waitForFunction(() => /발행|published/.test(
    document.querySelector("#status").textContent));
  check("a second confirm click sends nothing", dispatched.length === 2,
    `${dispatched.length} request(s)`);
  check("confirm publishes", dispatched.length === 2 && dispatched[1].dryRun === false,
    JSON.stringify(dispatched[1]));
  check("the gateway result is reported",
    /발행|published/.test(await page.textContent("#status")));

  const beforeEdit = dispatched.length;
  await page.click("#dispatch"); // fresh dry run after publishing
  await page.waitForSelector("#dispatch-confirm:not(.hidden)");
  await page.fill("#dsl", DSL + "\n# edited after the preview");
  const hiddenAfterEdit = await page.evaluate(() =>
    document.querySelector("#dispatch-confirm").classList.contains("hidden"));
  await page.evaluate(() => document.querySelector("#dispatch-go").click());
  check("editing the DSL invalidates the preview",
    hiddenAfterEdit && dispatched.length === beforeEdit + 1,
    `hidden=${hiddenAfterEdit}, requests=${dispatched.length}`);

  robots = [];
  await page.reload({ waitUntil: "networkidle" });
  const beforeNoRobot = dispatched.length;
  await page.fill("#dsl", DSL);
  await page.click("#dispatch");
  const noRobotStatus = await page.textContent("#status");
  check("a robot must be selected",
    /로봇/.test(noRobotStatus) && dispatched.length === beforeNoRobot,
    noRobotStatus);

  robots = ONLINE;
  rejectDry = true;
  await page.reload({ waitUntil: "networkidle" });
  await page.click("#robots button.robot:not([disabled])");
  await page.fill("#dsl", DSL);
  await page.click("#dispatch");
  await page.waitForFunction(() => /거부/.test(
    document.querySelector("#errors").textContent));
  const confirmHidden = await page.evaluate(() =>
    document.querySelector("#dispatch-confirm").classList.contains("hidden"));
  check("a rejected dry run shows errors, not the confirm bar", confirmHidden);

  for (const width of [420, 700, 1000, 1400]) {
    await page.setViewportSize({ width, height: 1200 });
    await page.waitForTimeout(100);
    const over = await page.evaluate(() => ({
      scroll: document.documentElement.scrollWidth,
      client: document.documentElement.clientWidth,
    }));
    check(`no horizontal overflow at ${width}px`, over.scroll <= over.client,
      `${over.scroll} vs ${over.client}`);
  }

  check("no console errors", consoleErrors.length === 0, consoleErrors.slice(0, 2).join(" | "));
  await browser.close();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
})().catch((e) => {
  console.error("browser test crashed:", e.message);
  process.exit(1);
});
