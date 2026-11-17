#!/usr/bin/env node
// Browser checks for the agent's web UI.
//
// These are not part of `cabal test`. The Haskell suite covers the compiler,
// the prompt, the loop and the HTTP surface; this drives the real page in a
// real browser, which is the only way to know the map draws, the route
// highlights, the example chips fill the box, and the panels say what they
// mean.
//
// Run it with the agent already listening:
//
//   cabal run robotdsl-agent -- --port 8790 --fleet http://127.0.0.1:8080
//   node tools/browser-test.js
//
// Without --fleet the fleet-dependent checks are skipped rather than failed:
// the map alone is a supported way to run, and a missing fleet is not a bug.

const { chromium } = require("playwright");

const PORT = process.env.AGENT_PORT || "8790";
const BASE = `http://127.0.0.1:${PORT}`;

let passed = 0;
let failed = 0;
let skipped = 0;

function check(name, ok, detail) {
  if (ok === "skip") {
    skipped++;
    console.log(`  SKIP  ${name}${detail ? " — " + detail : ""}`);
  } else if (ok) {
    passed++;
    console.log(`  ok    ${name}${detail ? " — " + detail : ""}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name}${detail ? " — " + detail : ""}`);
  }
}

(async () => {
  const browser = await chromium.launch({ args: ["--no-sandbox"] });
  const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });

  // Console errors are collected rather than ignored: a silent exception in
  // renderMap would leave an empty map and no other signal.
  const consoleErrors = [];
  page.on("pageerror", (e) => consoleErrors.push(e.message));
  page.on("console", (m) => {
    if (m.type() === "error") consoleErrors.push(m.text());
  });

  await page.goto(BASE, { waitUntil: "networkidle" });

  console.log("\nmap");
  const map = await page.evaluate(() => ({
    nodes: document.querySelectorAll("#map circle.node").length,
    edges: document.querySelectorAll("#map line.edge").length,
    labels: document.querySelectorAll("#map text.node-label").length,
    hasMap: !!document.querySelector("#map circle.node"),
    emptyShown: !document.querySelector("#map-empty").classList.contains("hidden"),
  }));
  check("the map draws nodes", map.nodes > 0, `${map.nodes} nodes`);
  check("the map draws the map's edges", map.edges > 0, `${map.edges} edges`);
  check("every node is labelled", map.labels === map.nodes,
    `${map.labels} labels for ${map.nodes} nodes`);
  check("the empty-map notice is hidden when there is a map", !map.emptyShown);

  // A label outside the viewBox is clipped by the SVG viewport, so the only
  // reliable check is against the geometry the browser actually used.
  const clipped = await page.evaluate(() => {
    const svg = document.querySelector("#map");
    const vb = svg.getAttribute("viewBox").split(/\s+/).map(Number);
    const out = [];
    svg.querySelectorAll("text.node-label").forEach((t) => {
      const b = t.getBBox();
      if (b.x < vb[0] || b.x + b.width > vb[0] + vb[2] ||
          b.y < vb[1] || b.y + b.height > vb[1] + vb[3]) {
        out.push(t.textContent);
      }
    });
    return out;
  });
  check("no label is clipped by the viewBox", clipped.length === 0,
    clipped.length ? clipped.join(", ") : "");

  const overlap = await page.evaluate(() => {
    const svg = document.querySelector("#map");
    const boxes = [...svg.querySelectorAll("text.node-label")].map((t) => ({
      id: t.textContent,
      b: t.getBBox(),
    }));
    const bad = [];
    for (let i = 0; i < boxes.length; i++) {
      for (let j = i + 1; j < boxes.length; j++) {
        const a = boxes[i].b, c = boxes[j].b;
        if (a.x < c.x + c.width && c.x < a.x + a.width &&
            a.y < c.y + c.height && c.y < a.y + a.height) {
          bad.push(`${boxes[i].id} / ${boxes[j].id}`);
        }
      }
    }
    return bad;
  });
  check("no two labels overlap", overlap.length === 0,
    overlap.length ? overlap.join(", ") : "");

  const labelOnNode = await page.evaluate(() => {
    const svg = document.querySelector("#map");
    const nodes = [...svg.querySelectorAll("circle.node")].map((c) => ({
      id: c.getAttribute("data-id"),
      r: Number(c.getAttribute("r")),
      x: Number(c.getAttribute("cx")),
      y: Number(c.getAttribute("cy")),
    }));
    const bad = [];
    svg.querySelectorAll("text.node-label").forEach((t) => {
      const b = t.getBBox();
      nodes.forEach((n) => {
        if (n.id === t.textContent) return;
        if (b.x < n.x + n.r && n.x - n.r < b.x + b.width &&
            b.y < n.y + n.r && n.y - n.r < b.y + b.height) {
          bad.push(`${t.textContent} on ${n.id}`);
        }
      });
    });
    return bad;
  });
  check("no label sits on another node", labelOnNode.length === 0,
    labelOnNode.length ? labelOnNode.join(", ") : "");

  console.log("\nexample prompts");
  const chips = await page.$$eval("#examples button.example", (bs) =>
    bs.map((b) => b.textContent));
  check("five example prompts are offered", chips.length === 5, `${chips.length}`);
  const before = await page.inputValue("#cmd");
  await page.click("#examples button.example:nth-child(5)");
  const after = await page.inputValue("#cmd");
  check("picking one fills the command box", after !== before && after.length > 0,
    after.slice(0, 30));
  const status = await page.textContent("#status");
  check("picking one explains what happened", /입력창/.test(status));

  console.log("\nscope");
  await page.click("#map circle.node >> nth=0");
  const scopeLabel = await page.textContent("#scope-label");
  check("clicking a node narrows the scope", /1개 노드/.test(scopeLabel), scopeLabel);
  const clearDisabled = await page.isDisabled("#scope-clear");
  check("the scope can be cleared", !clearDisabled);
  await page.click("#scope-clear");
  const cleared = await page.textContent("#scope-label");
  check("clearing restores the whole map", /전체 맵/.test(cleared), cleared);

  console.log("\nfleet");
  const robots = await page.$$eval("#robots button.robot", (bs) => bs.length);
  const robotsText = await page.textContent("#robots");
  if (robots > 0) {
    check("robots are listed", true, `${robots} robots`);
    const online = await page.$$eval("#robots button.robot:not([disabled])", (b) => b.length);
    check("online robots are selectable", online === robots,
      `${online} of ${robots}`);
    await page.click("#robots button.robot:not([disabled]) >> nth=0");
    const picked = await page.evaluate(() => state.selectedRobot);
    check("a robot can be picked", !!picked, picked);
  } else {
    // No fleet is a supported way to run, so this is not a failure. What must
    // hold is that the panel says something true.
    check("the robot panel explains itself", robotsText.length > 0, robotsText);
    check("no fleet configured", "skip", "run with --fleet to check robots");
  }

  console.log("\nend to end: command to route on the map");
  // This is the one thing a headless dump could not show: the generated DSL
  // reaching the map as a drawn route.
  const hasKey = !!process.env.OPENROUTER_API_KEY;
  if (!hasKey) {
    check("a command draws a route", "skip", "OPENROUTER_API_KEY not set");
  } else {
    await page.fill("#cmd",
      "AS-1W 에서 팔레트를 집어 DOOR-IN 을 지나 AS-4E 로 가져다줘");
    await page.click("#send");
    // The loop retries up to three times, each an LLM round trip.
    await page.waitForFunction(
      () => /성공|실패/.test(document.querySelector("#status").textContent),
      { timeout: 180000 });
    const st = await page.textContent("#status");
    const drawn = await page.evaluate(() => ({
      routes: document.querySelectorAll("#map line.route").length,
      used: document.querySelectorAll("#map circle.node.used").length,
      backtracks: document.querySelectorAll("#map line.route.backtrack").length,
    }));
    check("the command produced a mission", /성공/.test(st), st);
    check("the route is drawn on the map", drawn.routes > 0,
      `${drawn.routes} hops, ${drawn.used} nodes`);
    check("route nodes are highlighted", drawn.used > 0);
    const waste = await page.textContent("#waste");
    if (/없습니다/.test(waste)) {
      check("no backtracking on this route", true);
    } else {
      check("a backtracking route is called out", drawn.backtracks > 0,
        `${drawn.backtracks} red hop(s); ${waste.slice(0, 60)}`);
    }
    const dsl = await page.inputValue("#dsl");
    check("the generated DSL is editable", /order/.test(dsl));
  }

  console.log("\nlayout");
  for (const width of [420, 700, 1000, 1400]) {
    await page.setViewportSize({ width, height: 1200 });
    await page.waitForTimeout(150);
    const over = await page.evaluate(() => {
      const de = document.documentElement;
      return { scroll: de.scrollWidth, client: de.clientWidth };
    });
    check(`no horizontal overflow at ${width}px`,
      over.scroll <= over.client, `${over.scroll} vs ${over.client}`);
  }

  check("no console errors", consoleErrors.length === 0,
    consoleErrors.slice(0, 3).join(" | "));

  await browser.close();

  console.log(`\n${passed} passed, ${failed} failed, ${skipped} skipped`);
  process.exit(failed > 0 ? 1 : 0);
})().catch((e) => {
  console.error("browser test crashed:", e.message);
  process.exit(1);
});
