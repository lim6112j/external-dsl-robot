// robotdsl agent UI.
//
// 서버는 모든 생성을 파싱·검증하므로, 이 UI는 잘못된 DSL을 보여주거나 저장하는
// 법이 없다: 서버가 거부하면 오류만 표시한다.

// 브라우저 세션 동안 유지되는 대화 id. 서버가 이 id 로 대화 맥락을 이어간다.
const sessionId =
  "s" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

const $ = (id) => document.getElementById(id);

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

function usageText(u) {
  if (!u) return "";
  return ", 토큰 " + u[0] + "+" + u[1];
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
  const r = await api("/api/command", { text: text, sessionId: sessionId });
  if (r.ok) {
    $("dsl").value = r.dsl;
    showMessages(r.messages);
    showErrors([]);
    setStatus(
      "성공 — " + r.attempts + "회 시도" + usageText(r.usage), "ok");
  } else {
    // 실패해도 마지막 DSL은 보여준다. 운영자가 직접 고칠 수 있게.
    if (r.dsl) $("dsl").value = r.dsl;
    showMessages([]);
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
  const r = await api("/api/compile", { dsl: dsl });
  if (r.ok) {
    showMessages(r.messages);
    showErrors([]);
    setStatus("컴파일 성공", "ok");
  } else {
    showMessages([]);
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
  showErrors([]);
  setStatus("대화를 초기화했습니다", "ok");
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

async function loadContext() {
  const c = await api("/api/context");
  const dl = $("meta");
  const rows = [
    ["모델", c.model || "-"],
    ["맵", c.hasMap ? (c.mapId || "-") + " (" + (c.nodes || []).length + "개 노드)" : "없음"],
    ["버전", c.version || "-"],
    ["음성", c.sttReady ? "사용 가능" : "미빌드 (tools/stt/build.sh)"],
  ];
  dl.innerHTML = rows
    .map(([k, v]) => "<dt>" + k + "</dt><dd>" + v + "</dd>")
    .join("");
  if (!c.sttReady) {
    $("listen").disabled = true;
    $("listen").title = "음성 헬퍼가 빌드되지 않았습니다. tools/stt/build.sh 를 실행하세요.";
  }
}

$("send").addEventListener("click", () => sendCommand($("cmd").value));
$("listen").addEventListener("click", listen);
$("recompile").addEventListener("click", recompile);
$("save").addEventListener("click", save);
$("reset").addEventListener("click", resetSession);

$("cmd").addEventListener("keydown", (e) => {
  if (e.key === "Enter") sendCommand($("cmd").value);
});

loadContext();
