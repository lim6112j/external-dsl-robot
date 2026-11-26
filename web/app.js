// robotdsl agent UI.
//
// 서버는 모든 생성을 파싱·검증하므로, 이 UI는 잘못된 DSL을 보여주거나 저장하는
// 법이 없다: 서버가 거부하면 오류만 표시한다.
//
// 이 UI는 임무를 발행하지 않고, 맵에 어떻게 진행할지만 보여준다. 발행은
// API 로 한다: POST /api/dispatch (dry-run 기본) 또는 /api/instant-actions.

// 브라우저 세션 동안 유지되는 대화 id. 서버가 이 id 로 대화 맥락을 이어간다.
const sessionId =
  "s" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

// dry-run으로 확인한 요청. DSL이나 로봇이 바뀌면 반드시 비운다 — 오래된
// 경로가 실제 로봇으로 보내지지 않게 하는のが 이 값의 유일한 목적이다.
let dispatchPending = null;

const $ = (id) => document.getElementById(id);

// 화면 상태.
//   coords  그릴 수 있는 노드만 (좌표가 없는 노드는 맵에 놓을 수 없다)
//   scope   운영자가 고른 노드 부분집합. 비면 전체 맵이 어휘이다.
const state = {
  coords: new Map(),
  edges: [],
  scope: new Set(),
  selectedRobot: null,
  // --fleet 이 주어졌는지. 로봇이 0 대일 때 "연결 안 됨" 과 "연결됐는데
  // 로봇이 없음" 을 가르는 유일한 근거다.
  hasFleet: false,
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

// 게이트웨이가 표현 못 하는 것. 여기서는 경고로 보여주지만 같은 조건은
// /api/dispatch 에서 투입 전 거부 사유가 된다.
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

// 경로 낭비: 홉은 전부 유효하지만 로봇이 되돌아다니는 구간.
// 맵 검사를 통과한 경로라서 오류가 아니라 경고다.
function showWaste(pv) {
  const el = $("waste");
  const list = (pv && pv.waste) || [];
  if (list.length === 0) {
    el.textContent = "없습니다";
    el.className = "waste empty";
    return;
  }
  el.textContent = list.map((e) => "• " + e).join("\n");
  el.className = "waste";
}

function usageText(u) {
  if (!u) return "";
  return ", 토큰 " + u[0] + "+" + u[1];
}

// ---------------------------------------------------------------------------
// 맵
// ---------------------------------------------------------------------------

// 맵 안에서 쓰는 크기들. 전부 맵 단위(미터)이고, 픽셀이 아니다. 맵 패널이
// 약 660px 에 viewBox 폭 43 유닛이므로 1 유닛 이 약 15px 다.
const NODE_R = 0.75;      // 노드 원 반경. 1.2 였을 때 지름 37px 라 경로를 덮었다.
const LABEL_FS = 0.575;   // 라벨 폰트. 1.15 의 절반.
const LABEL_CH = 0.345;   // 문자 하나 너비(LABEL_FS * 0.6).

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
  // 라벨이 viewBox 밖으로 나가면 잘린다. 라벨은 노드에서 원 반경 + 여유 +
  // 폰트 높이만큼(약 1.8 유닛) 나가고, 옆으로는 제일 긴 id(CONV-OUT)가
  // 절반씩 1.4 유닛 나간다. 맵 단위로 고정된 크기이므로 여유도 맵 단위로
  // 고정해서 준다. 지도가 크면 여유도 비례해서 조금 더 준다.
  const pad = Math.max(3.5, spanX * 0.06, spanY * 0.06);
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
    pts.push({
      id: n.id,
      x: n.x,
      y: n.y,
      rel: pv.released ? pv.released[i] : true,
    });
  }
  for (let i = 0; i + 1 < pts.length; i++) {
    const a = pts[i], b = pts[i + 1];
    // 목적지가 released false 이면 그 구간이 horizon 이다.
    let cls = b.rel ? "route" : "route horizon";
    // 방금 떠난 노드로 되돌아가는 구간은 낭비다. 홉 자체는 유효해서 맵
    // 검사를 통과하지만, 로봇이 같은 자리를 두 번 지나는 것이다.
    if (i > 0 && pts[i - 1].id === b.id) cls += " backtrack";
    parts.push('<line class="' + cls + '" x1="' + a.x + '" y1="' + a.y +
               '" x2="' + b.x + '" y2="' + b.y + '"/>');
  }

  // 3. 노드. 경로에 포함된 것은 강조한다.
  const onRoute = new Set(pts.map((p) => p.id));
  for (const [id, p] of nodes) {
    const scoped = state.scope.has(id);
    const used = onRoute.has(id);
    let cls = "node";
    if (scoped) cls += " scoped";
    if (used) cls += " used";
    parts.push('<circle class="' + cls + '" cx="' + p.x + '" cy="' + p.y +
               '" r="' + NODE_R + '" data-id="' + id + '"/>');
  }

  // 4. 라벨. 자리가 없는 쪽이 있어 후보를 네 개 두고 고른다.
  //
  // 한쪽에만 붙이면 안 된다. 가운데 열은 세로 2 유닛 간격이라 반경 0.75 인 원
  // 사이 틈이 0.5 유닛 밖에 없고, 라벨은 1.15 유닛이라 위아래로는 낄 자리가
  // 없다 — AS-1M 의 라벨이 RK-AM 원과 겹쳤던 것이 그것이다. 그래서 기본은
  // 옆이다. 그런데 동쪽 열은 오른쪽이 막혀 왼쪽으로 가고, 그게 DOOR-OUT
  // 라벨과 겹친다. 맨 위줄(y=0)은 위가 비어 있으니 위에 붙이면 자유롭다.
  //
  // 후보 순서: 오른쪽, 왼쪽, 위, 아래. 다른 라벨·원과 겹치지 않는 첫 번째를
  // 고르고, 네 개 다 겹치면 마지막 후보를 쓴다(겹쳐도 라벨이 없는 것보다 낫다).
  const placed = [];
  for (const [id, p] of nodes) {
    const w = id.length * LABEL_CH;
    const h = LABEL_FS;
    const gap = 0.25;  // 노드 원과 라벨 사이 여유
    const cands = [
      { x: p.x + NODE_R + gap, y: p.y + 0.42, anchor: "start" },
      { x: p.x - NODE_R - gap, y: p.y + 0.42, anchor: "end" },
      { x: p.x, y: p.y - NODE_R - gap - 0.1, anchor: "middle" },
      { x: p.x, y: p.y + NODE_R + gap + h, anchor: "middle" },
    ];
    const pick = cands.find((c) => fits(c, id, w, h)) || cands[cands.length - 1];
    placed.push({ id: id, box: boxOf(pick, id, w, h) });
    parts.push('<text class="node-label" x="' + pick.x + '" y="' + pick.y +
               '" text-anchor="' + pick.anchor + '">' + id + "</text>");
  }

  // 후보 자리가 실제로 비어 있는지. viewBox 안에 들어오고, 이미 놓인 라벨이나
  // 원과 겹치지 않아야 한다.
  function fits(c, id, w, h) {
    const b = boxOf(c, id, w, h);
    if (b[0] < minX - pad || b[2] > maxX + pad) return false;
    if (b[1] < minY - pad || b[3] > maxY + pad) return false;
    for (const q of placed) {
      if (b[0] < q.box[2] && q.box[0] < b[2] &&
          b[1] < q.box[3] && q.box[1] < b[3]) return false;
    }
    for (const [oid, op] of nodes) {
      if (oid === id) continue;
      if (b[0] < op.x + NODE_R && op.x - NODE_R < b[2] &&
          b[1] < op.y + NODE_R && op.y - NODE_R < b[3]) return false;
    }
    return true;
  }

  function boxOf(c, id, w, h) {
    let x0, x1;
    if (c.anchor === "start") { x0 = c.x; x1 = c.x + w; }
    else if (c.anchor === "end") { x0 = c.x - w; x1 = c.x; }
    else { x0 = c.x - w / 2; x1 = c.x + w / 2; }
    return [x0, c.y - h, x1, c.y + h * 0.3];
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

// 빈 로봇 목록은 서로 다른 세 가지를 뜻하는데, 전부 같은 말로 보여주면
// 운영자가 엉뚱한 곳을 고친다:
//   --fleet 을 안 줌 / 게이트웨이에 닿지 못함 / 연결됐는데 로봇이 0대.
function renderRobots(robots, fleetError) {
  const el = $("robots");
  if (robots && robots.length > 0) {
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
          clearDispatchPending();
          syncRobotUI();
        });
      }
      el.appendChild(b);
    }
    return;
  }
  el.className = "robots empty";
  if (fleetError) {
    el.textContent = "플릿에 연결할 수 없습니다: " + fleetError;
  } else if (state.hasFleet) {
    el.textContent =
      "연결됐지만 로봇이 보이지 않습니다. 시뮬레이터를 켰나요?";
  } else {
    el.textContent =
      "플릿에 연결되지 않았습니다. --fleet URL 로 게이트웨이를 주세요.";
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
    clearDispatchPending();
    showMessages(r.messages);
    showUnplaced(r.preview);
    showWarnings(r.preview);
    showWaste(r.preview);
    renderMap(r.preview);
    showErrors([]);
    setStatus("성공 — " + r.attempts + "회 시도" + usageText(r.usage), "ok");
  } else {
    // 실패해도 마지막 DSL은 보여준다. 운영자가 직접 고칠 수 있게.
    if (r.dsl) $("dsl").value = r.dsl;
    showMessages([]);
    showUnplaced(null);
    showWarnings(null);
  showWaste(null);
    showWaste(null);
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
    clearDispatchPending();
    showMessages(r.messages);
    showUnplaced(r.preview);
    showWarnings(r.preview);
    showWaste(r.preview);
    renderMap(r.preview);
    showErrors([]);
    setStatus("컴파일 성공", "ok");
  } else {
    showMessages([]);
    showUnplaced(null);
    showWarnings(null);
  showWaste(null);
    showWaste(null);
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

function clearDispatchPending() {
  dispatchPending = null;
  $("dispatch-confirm").classList.add("hidden");
  $("dispatch-preview").textContent = "";
}

// 첫 클릭: 아무것도 발행하지 않고 게이트웨이에 보낼 요청을 보여준다.
async function dispatch() {
  const dsl = $("dsl").value;
  if (!dsl.trim()) {
    setStatus("투입할 DSL이 없습니다", "err");
    return;
  }
  if (!state.selectedRobot) {
    setStatus("투입할 로봇을 먼저 선택하세요", "err");
    return;
  }
  clearDispatchPending();
  setStatus("dry-run 중…", "busy");
  const r = await api("/api/dispatch",
    { dsl: dsl, robotId: state.selectedRobot, dryRun: true });
  if (!r.ok || r.errors) {
    showErrors(r.errors && r.errors.length ? r.errors
      : [r.error || "알 수 없는 오류"]);
    setStatus("dry-run 실패", "err");
    return;
  }
  showErrors([]);
  $("dispatch-preview").textContent = JSON.stringify(r.request, null, 2);
  dispatchPending = { dsl: dsl, robotId: state.selectedRobot };
  $("dispatch-confirm").classList.remove("hidden");
  setStatus("투입 요청을 확인하세요", "ok");
}

// 두 번째 클릭: 방금 보여준 그 요청을 실제로 발행한다.
async function dispatchGo() {
  if (!dispatchPending) {
    setStatus("먼저 실제 투입 으로 요청을 확인하세요", "err");
    return;
  }
  const pending = dispatchPending;
  setStatus("투입 중…", "busy");
  const r = await api("/api/dispatch",
    { dsl: pending.dsl, robotId: pending.robotId, dryRun: false });
  if (!r.ok || r.errors) {
    showErrors(r.errors && r.errors.length ? r.errors
      : [r.error || "알 수 없는 오류"]);
    setStatus("투입 실패", "err");
    return;
  }
  showErrors([]);
  const gw = r.gateway || {};
  clearDispatchPending();
  setStatus("발행됨: " + (gw.orderId || "order")
    + (gw.headerId ? " (headerId " + gw.headerId + ")" : ""), "ok");
}

function dispatchCancel() {
  clearDispatchPending();
  setStatus("투입을 취소했습니다", "");
}

async function resetSession() {
  await api("/api/reset", { sessionId: sessionId });
  $("dsl").value = "";
  showMessages([]);
  showUnplaced(null);
  showWarnings(null);
  showWaste(null);
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
  state.hasFleet = !!c.hasFleet;
  renderRobots(c.robots, c.fleetError);
  syncRobotUI();

  const canDispatch = c.dispatchAllowed !== false;
  $("dispatch").disabled = !canDispatch;
  $("dispatch").title = canDispatch
    ? "먼저 dry-run으로 요청을 보여줍니다"
    : "이 에이전트는 --allow-dispatch 없이 실행되어 실제 발행을 할 수 없습니다";
  clearDispatchPending();

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
$("dispatch").addEventListener("click", dispatch);
$("dispatch-go").addEventListener("click", dispatchGo);
$("dispatch-cancel").addEventListener("click", dispatchCancel);
$("dsl").addEventListener("input", clearDispatchPending);
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
