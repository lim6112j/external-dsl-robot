// robotdsl agent UI.
//
// 서버는 모든 생성을 파싱·검증하므로, 이 UI는 잘못된 DSL을 보여주거나 저장하는
// 법이 없다: 서버가 거부하면 오류만 표시한다.
//
// Phase 1 은 읽기 전용이다. 이 UI는 임무를 발행하지 않고, 맵에 어떻게
// 진행할지만 보여준다. 투입 버튼은 Phase 2 에서 추가된다.

// 브라우저 세션 동안 유지되는 대화 id. 서버가 이 id 로 대화 맥락을 이어간다.
const sessionId =
  "s" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

const $ = (id) => document.getElementById(id);

// 화면 상태.
//   coords  그릴 수 있는 노드만 (좌표가 없는 노드는 맵에 놓을 수 없다)
//   scope   운영자가 고른 노드 부분집합. 비면 전체 맵이 어휘이다.
const state = {
  coords: new Map(),
  edges: [],
  scope: new Set(),
  selectedRobot: null,
};

// 미리 적어둔 작업지시. 입력창에 직접 치는 대신 고르면 되므로, 처음 쓰는
// 사람이 뭘 물어봐야 할지 감을 잡을 수 있다. 이 문장들은 plant-b/l1 맵의
// 실제 노드 이름을 쓴다 — 다른 맵을 쓰면 주소가 안 맞을 수 있다.
const EXAMPLES = [
  "RK-AM 에서 팔레트를 집어 CHG-01 로 가져다줘",
  "랙 A 중앙에서 컨베이어 출구까지 팔레트를 옮겨줘",
  "STG-01 에서 팔레트를 집어 AS-4E 근처에 내려놔줘",
  "CHG-01 에 가서 30 초 동안 충전해줘",
  "AS-1W 에서 팔레트를 집어 DOOR-IN 을 지나 AS-4E 로 가져다줘",
];

async function api(path, body) {
  const opts = {};
  if (body !== undefined) {
    opts.method = "POST";
    opts.headers = { "Content-Type": "application/json" };
    opts.body = JSON.stringify(body);
  }
  let res;
  try {
    res = await fetch(path, opts);
  } catch (e) {
    return { ok: false, error: "서버에 연결할 수 없습니다: " + e };
  }
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch (e) {
    return {
      ok: false,
      error: "서버가 JSON 아닌 응답을 보냈습니다 (" + res.status + "): " +
             text.slice(0, 200),
    };
  }
}

function setStatus(msg, kind) {
  const el = $("status");
  el.textContent = msg;
  el.className = "status" + (kind ? " " + kind : "");
}

// ---------------------------------------------------------------------------
// 출력 패널
// ---------------------------------------------------------------------------

function showErrors(list) {
  const el = $("errors");
  if (!list || list.length === 0) {
    el.textContent = "없습니다";
    el.className = "errors empty";
    return;
  }
  el.textContent = list.map((e) => "• " + e).join("\n");
  el.className = "errors";
}

function showMessages(msgs) {
  const el = $("preview");
  if (!msgs || msgs.length === 0) {
    el.textContent = "아직 없습니다";
    el.className = "preview empty";
    return;
  }
  el.textContent = msgs
    .map((m) => JSON.stringify(m, null, 2))
    .join("\n\n");
  el.className = "preview";
}

// 맵에 없어서 그릴 수 없는 노드와 홉. 미리보기를 막지 않고 보고만 한다.
function showUnplaced(pv) {
  const el = $("unplaced");
  const list = (pv && pv.unplaced) || [];
  if (list.length === 0) {
    el.textContent = "없습니다";
    el.className = "unplaced empty";
    return;
  }
  el.textContent = list.map((e) => "• " + e).join("\n");
  el.className = "unplaced";
}

// 게이트웨이가 표현 못 하는 것. Phase 1 은 발행하지 않으므로 경고일 뿐이다.
function showWarnings(pv) {
  const el = $("warnings");
  const list = (pv && pv.warnings) || [];
  if (list.length === 0) {
    el.textContent = "없습니다";
    el.className = "warnings empty";
    return;
  }
  el.textContent = list.map((e) => "• " + e).join("\n");
  el.className = "warnings";
}

function usageText(u) {
  if (!u) return "";
  return ", 토큰 " + u[0] + "+" + u[1];
}

// ---------------------------------------------------------------------------
// 맵
// ---------------------------------------------------------------------------

// 미리보기가 있으면 경로를 얹어 그리고, 없으면 맵만 그린다.
//
// 한 번에 innerHTML 로 다시 그리는 이유: insertAdjacentHTML 은 SVG 요소에서
// 네임스페이스 처리가 브라우저마다 달라 조용히 실패할 수 있다.
function renderMap(pv) {
  const svg = $("map");
  const nodes = [...state.coords.entries()];
  if (nodes.length === 0) {
    svg.innerHTML = "";
    $("map-empty").classList.remove("hidden");
    return;
  }
  $("map-empty").classList.add("hidden");

  const xs = nodes.map(([, p]) => p.x);
  const ys = nodes.map(([, p]) => p.y);
  const minX = Math.min(...xs), maxX = Math.max(...xs);
  const minY = Math.min(...ys), maxY = Math.max(...ys);
  const spanX = maxX - minX || 1;
  const spanY = maxY - minY || 1;
  const pad = Math.max(2, spanX * 0.06);
  svg.setAttribute("viewBox",
    (minX - pad) + " " + (minY - pad) + " " +
    (spanX + 2 * pad) + " " + (spanY + 2 * pad));

  const parts = [];

  // 1. 맵의 엣지. 좌표가 없는 쪽 끝점은 그릴 수 없다.
  for (const e of state.edges) {
    const a = state.coords.get(e.from);
    const b = state.coords.get(e.to);
    if (!a || !b) continue;
    parts.push('<line class="edge" x1="' + a.x + '" y1="' + a.y +
               '" x2="' + b.x + '" y2="' + b.y + '"/>');
  }

  // 2. 경로. 좌표가 없는 노드는 건너뛰고, unplaced 패널이 이유를 알린다.
  const route = (pv && pv.nodes) || [];
  const pts = [];
  for (let i = 0; i < route.length; i++) {
    const n = route[i];
    if (n.x === null || n.y === null) continue;
    pts.push({ x: n.x, y: n.y, rel: pv.released ? pv.released[i] : true });
  }
  for (let i = 0; i + 1 < pts.length; i++) {
    const a = pts[i], b = pts[i + 1];
    // 목적지가 released false 이면 그 구간이 horizon 이다.
    const cls = b.rel ? "route" : "route horizon";
    parts.push('<line class="' + cls + '" x1="' + a.x + '" y1="' + a.y +
               '" x2="' + b.x + '" y2="' + b.y + '"/>');
  }

  // 3. 노드. 경로에 포함된 것은 강조한다.
  const onRoute = new Set(pts.map((p) => p.x + "," + p.y));
  for (const [id, p] of nodes) {
    const scoped = state.scope.has(id);
    const used = onRoute.has(p.x + "," + p.y);
    let cls = "node";
    if (scoped) cls += " scoped";
    if (used) cls += " used";
    parts.push('<circle class="' + cls + '" cx="' + p.x + '" cy="' + p.y +
               '" r="1.2" data-id="' + id + '"/>');
  }

  // 4. 라벨은 맨 위에. 노드가 35 개쯤 되면 겹치므로 호버로 확대한다.
  for (const [id, p] of nodes) {
    parts.push('<text class="node-label" x="' + p.x + '" y="' + (p.y - 1.9) +
               '">' + id + "</text>");
  }

  svg.innerHTML = parts.join("\n");

  svg.querySelectorAll("circle.node").forEach((c) =>
    c.addEventListener("click", () => toggleScope(c.getAttribute("data-id"))));
}

function toggleScope(id) {
  if (state.scope.has(id)) state.scope.delete(id);
  else state.scope.add(id);
  syncScopeUI();
}

function syncScopeUI() {
  const n = state.scope.size;
  $("scope-label").textContent =
    n === 0 ? "구역: 전체 맵" : "구역: " + n + "개 노드로 제한";
  $("scope-clear").disabled = n === 0;
  $("map").querySelectorAll("circle.node").forEach((c) => {
    c.classList.toggle("scoped", state.scope.has(c.getAttribute("data-id")));
  });
}

// ---------------------------------------------------------------------------
// 로봇
// ---------------------------------------------------------------------------

function renderRobots(robots) {
  const el = $("robots");
  if (!robots || robots.length === 0) {
    el.innerHTML = '<span class="empty">플릿에 연결되지 않았습니다</span>';
    el.className = "robots empty";
    return;
  }
  el.className = "robots";
  el.innerHTML = "";
  for (const r of robots) {
    const b = document.createElement("button");
    b.className = "robot" + (r.online ? "" : " offline");
    b.setAttribute("data-robot", r.robotId);
    b.disabled = !r.online;
    const st = r.driving ? "주행 중 · " + (r.orderId || "?") : "대기";
    b.innerHTML = "<b>" + r.robotId + "</b><span>" + st + "</span>";
    b.title = r.online
      ? "이 로봇에게 명령합니다"
      : "오프라인이라 선택할 수 없습니다";
    if (r.online) {
      b.addEventListener("click", () => {
        state.selectedRobot =
          state.selectedRobot === r.robotId ? null : r.robotId;
        syncRobotUI();
      });
    }
    el.appendChild(b);
  }
}

function syncRobotUI() {
  $("robots").querySelectorAll("button.robot").forEach((b) => {
    b.classList.toggle("picked",
      b.getAttribute("data-robot") === state.selectedRobot);
  });
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

async function sendCommand(text) {
  if (!text || !text.trim()) {
    setStatus("명령을 입력하세요", "err");
    return;
  }
  setStatus("생성 중…", "busy");
  const body = { text: text, sessionId: sessionId };
  if (state.selectedRobot) body.robotId = state.selectedRobot;
  if (state.scope.size > 0) body.scope = [...state.scope];
  const r = await api("/api/command", body);
  if (r.ok) {
    $("dsl").value = r.dsl;
    showMessages(r.messages);
    showUnplaced(r.preview);
    showWarnings(r.preview);
    renderMap(r.preview);
    showErrors([]);
    setStatus("성공 — " + r.attempts + "회 시도" + usageText(r.usage), "ok");
  } else {
    // 실패해도 마지막 DSL은 보여준다. 운영자가 직접 고칠 수 있게.
    if (r.dsl) $("dsl").value = r.dsl;
    showMessages([]);
    showUnplaced(null);
    showWarnings(null);
    renderMap(null);
    showErrors(r.errors && r.errors.length ? r.errors : [r.error || "알 수 없는 오류"]);
    setStatus("실패", "err");
  }
}

async function listen() {
  setStatus("듣는 중… 말씀하세요", "busy");
  const r = await api("/api/listen", {});
  if (r.ok && r.text) {
    $("cmd").value = r.text;
    setStatus("인식: " + r.text, "ok");
    await sendCommand(r.text);
  } else {
    setStatus(r.error || "음성을 인식하지 못했습니다", "err");
  }
}

async function recompile() {
  const dsl = $("dsl").value;
  if (!dsl.trim()) {
    setStatus("고칠 DSL이 없습니다", "err");
    return;
  }
  setStatus("컴파일 중…", "busy");
  // 직접 고친 DSL 은 구역 제한 없이 전체 맵으로 검사한다. 운영자가 이미 쓴
  // 노드를 구역 때문에 숨기면 고칠 근거가 사라진다.
  const r = await api("/api/compile", { dsl: dsl });
  if (r.ok) {
    showMessages(r.messages);
    showUnplaced(r.preview);
    showWarnings(r.preview);
    renderMap(r.preview);
    showErrors([]);
    setStatus("컴파일 성공", "ok");
  } else {
    showMessages([]);
    showUnplaced(null);
    showWarnings(null);
    renderMap(null);
    showErrors(r.errors && r.errors.length ? r.errors : [r.error || "알 수 없는 오류"]);
    setStatus("컴파일 실패", "err");
  }
}

async function save() {
  const dsl = $("dsl").value;
  const path = $("path").value;
  if (!dsl.trim()) {
    setStatus("저장할 DSL이 없습니다", "err");
    return;
  }
  if (!path.trim()) {
    setStatus("저장 경로를 입력하세요", "err");
    return;
  }
  setStatus("저장 중…", "busy");
  // 서버가 저장 전에 다시 파싱·검증한다. 실패하면 파일은 만들어지지 않는다.
  const r = await api("/api/save", { dsl: dsl, path: path });
  if (r.ok) {
    setStatus("저장됨: " + r.path, "ok");
  } else {
    showErrors(r.errors && r.errors.length ? r.errors : [r.error || "알 수 없는 오류"]);
    setStatus("저장 실패", "err");
  }
}

async function resetSession() {
  await api("/api/reset", { sessionId: sessionId });
  $("dsl").value = "";
  showMessages([]);
  showUnplaced(null);
  showWarnings(null);
  renderMap(null);
  showErrors([]);
  setStatus("대화를 초기화했습니다", "ok");
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

async function loadContext() {
  const c = await api("/api/context");
  const dl = $("meta");
  const nodeCount = (c.nodes || []).length;
  const rows = [
    ["모델", c.model || "-"],
    ["맵", c.hasMap
      ? (c.mapId || "-") + " (" + nodeCount + "개 노드)"
      : "없음"],
    ["버전", c.version || "-"],
    ["음성", c.sttReady ? "사용 가능" : "미빌드 (tools/stt/build.sh)"],
  ];
  if (c.fleetError) rows.push(["플릿", c.fleetError]);
  dl.innerHTML = rows
    .map(([k, v]) => "<dt>" + k + "</dt><dd>" + v + "</dd>")
    .join("");

  state.coords = new Map((c.nodes || []).map((n) => [n.id, { x: n.x, y: n.y }]));
  state.edges = c.edges || [];
  state.scope = new Set();
  renderMap(null);
  syncScopeUI();
  renderRobots(c.robots);
  syncRobotUI();

  if (!c.sttReady) {
    $("listen").disabled = true;
    $("listen").title = "음성 헬퍼가 빌드되지 않았습니다. tools/stt/build.sh 를 실행하세요.";
  }
}

// 예시 문구를 칩으로 그린다. 고르면 입력창에 들어가고, 바로 보낼 수 있다.
function renderExamples() {
  const box = $("examples");
  box.innerHTML = "";
  EXAMPLES.forEach((text) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "example";
    b.textContent = text;
    b.title = "이 문장을 입력창에 넣습니다";
    b.addEventListener("click", () => {
      $("cmd").value = text;
      $("cmd").focus();
      setStatus("예시를 입력창에 넣었습니다. 보내기 를 누르세요.", "");
    });
    box.appendChild(b);
  });
}

$("send").addEventListener("click", () => sendCommand($("cmd").value));
$("listen").addEventListener("click", listen);
$("recompile").addEventListener("click", recompile);
$("save").addEventListener("click", save);
$("reset").addEventListener("click", resetSession);
$("scope-clear").addEventListener("click", () => {
  state.scope = new Set();
  syncScopeUI();
});

$("cmd").addEventListener("keydown", (e) => {
  if (e.key === "Enter") sendCommand($("cmd").value);
});

renderExamples();
loadContext();
