# robotdsl

An **external text DSL** for writing mobile-robot missions as plain text, and a
compiler that lowers them to wire-ready **VDA 5050 v3.0.0** JSON.

VDA 5050 is the VDMA standard that sits between a fleet manager and the AGVs and
AMRs it controls. Its messages are verbose: every order carries mandatory
bookkeeping the operator should never have to think about, and several fields
are easy to get subtly wrong in ways a broker will silently reject.

robotdsl lets an operator describe *what should happen* and fills in the rest.

```
$ robotdsl compile examples/palletizing.robot --out out/
out/order-pallet-1.order.json  (vda5050/v3/acme/AMR-001/order)
```

Target standard: **VDA 5050 v3.0.0**, including the `zoneSet` message and the
full `zoneType` vocabulary (`BLOCKED`, `LINE_GUIDED`, `RELEASE`,
`COORDINATED_REPLANNING`, `SPEED_LIMIT`, `ACTION`, `PRIORITY`, `PENALTY`,
`DIRECTED`, `BIDIRECTED`).

> **처음 작성하시나요?** 단계별 작성 가이드:
> [`docs/DSL-GUIDE.md`](docs/DSL-GUIDE.md) — 최소 파일에서 시작해 픽앤드롭,
> 충전, 순찰, 속도 제한 존, 정지/재개/중단까지, 오류 메시지 해설 포함.
> 이 README는 문법 전체 레퍼런스입니다.

---

## Quick start (how to use)

The shortest useful path, from zero to a wire-ready VDA 5050 message:

```bash
# 0. build
mkdir -p ~/.local/bin
cabal install exe:robotdsl --installdir ~/.local/bin --overwrite-policy=always
export PATH="$HOME/.local/bin:$PATH"

# 1. try an example
robotdsl check examples/palletizing.robot

# 2. look at what one produces
robotdsl compile examples/palletizing.robot | less

# 3. write your own mission
cp examples/palletizing.robot my-mission.robot
$EDITOR my-mission.robot

# 4. compile it to JSON files (one per message, with the MQTT topic echoed)
robotdsl compile my-mission.robot --out out/
```

A typical workflow from there:

1. **Check** while editing — `robotdsl check my-mission.robot` gives parse and
   semantic errors with line and column, and never touches the filesystem.
2. **Compile** — `robotdsl compile my-mission.robot --out out/` also validates
   every message against the official v3.0.0 schemas and writes one JSON file
   per message, echoing the MQTT topic it belongs on
   (e.g. `vda5050/v3/acme/AMR-001/order`). Exit code 0 only when everything
   passed.
3. **Publish** — the echoed topics are the wire format, so `out/*.json` can be
   piped straight into your MQTT publisher.
4. **Cross-check** — `python3 tools/verify-output.py out/` re-validates the
   output with an independent Python implementation (274 checks).

Two gotchas on a first run: run `compile` from the project root (or pass
`--schema-dir "$PWD/schemas/vda5050/3.0.0"`), and note the directory is
`examples`, plural. See [Troubleshooting](#troubleshooting).

If you would rather *talk* your mission into existence, skip to
[AI agent interface](#ai-agent-interface).

## Build

```bash
cabal build          # library, CLI and the agent
cabal test           # 139 tests
```

Requires GHC 9.10 (developed against 9.10.3) and cabal. The core DSL depends on
`aeson`, `megaparsec`, `text`, `containers` and `time`. The agent additionally
needs `warp`, `wai` and `http-conduit`; those live in a separate private
sublibrary so that `robotdsl` itself never links a web server.

```bash
cabal run robotdsl -- check examples/palletizing.robot
cabal run robotdsl -- compile examples/palletizing.robot --out out/
```

The binary is not put on your `PATH` by `cabal build`. See
[Troubleshooting](#troubleshooting) for how to run it either way, and note that
`compile` resolves its schema directory relative to the current directory.

## AI agent interface

`robotdsl-agent` puts a chat and voice front end on the compiler. An operator
types or speaks a request in Korean; a model on OpenRouter turns it into
robotdsl source; the existing parser and validator then decide whether that
source is acceptable.

The model is only ever a translator. Nothing reaches the operator, nothing is
written to disk, and no mission is published, unless `RobotDSL.Parser` and
`RobotDSL.Validate` both accept the output. When they reject it, the exact
error is fed back for another attempt, up to three times.

Publishing is a separate, explicit step: `/api/dispatch` dry-runs by default,
and even a request with `"dryRun":false` only publishes when the agent was
started with `--allow-dispatch`.

```bash
# build the voice helper once (macOS Speech framework, on-device)
tools/stt/build.sh

cabal run robotdsl-agent -- --map ../로봇관제시스템/deploy/maps/plant-b.l1.json
# then open http://127.0.0.1:8790
```

| route | purpose |
|---|---|
| `POST /api/command` | generate DSL from text, on a session |
| `POST /api/listen` | transcribe one utterance via the Swift helper |
| `POST /api/compile` | recompile DSL edited in the browser |
| `POST /api/dispatch` | build a gateway order from the DSL (dry run by default) |
| `POST /api/instant-actions` | send pause/resume/cancel to one robot |
| `POST /api/save` | write the file, after re-validating |
| `POST /api/reset` | clear the conversation |
| `GET /api/context` | vocabulary and identity in use |

### Dispatching a mission

The browser UI generates and validates DSL; the API can hand a validated order
to the fleet gateway's `POST /api/orders`. Start the agent with `--fleet` (so it
can check the robot and the map) and add `--allow-dispatch` only when publishing
is intended:

```bash
# See the exact OrderRequest without writing anything (default).
python3 -c 'import json; print(json.dumps({"dsl": open("mission.robot").read(), "robotId": "acme:AMR-001"}))' \
  | curl -s -X POST http://127.0.0.1:8790/api/dispatch \
      -H 'Content-Type: application/json' -d @-

# With --allow-dispatch, the same request plus "dryRun":false publishes.
# The response carries the gateway's publication result.
python3 -c 'import json; print(json.dumps({"dsl": open("mission.robot").read(), "robotId": "acme:AMR-001", "dryRun": False}))' \
  | curl -s -X POST http://127.0.0.1:8790/api/dispatch \
      -H 'Content-Type: application/json' -d @-

# Instant actions use the same dry-run/allow-dispatch gates:
curl -s -X POST http://127.0.0.1:8790/api/instant-actions \
  -H 'Content-Type: application/json' \
  -d '{"robotId":"acme:AMR-001","actions":["startPause"]}'
```

A dispatch is rejected before any write when the DSL declares zones, edge
actions or constraints, nodes or hops absent from the map, two orders, no
route, or a robot other than the one selected. The selected robot must be
online and known to the gateway; an `orderId` already published in this
session is refused. `--allow-dispatch` is off by default because the agent has
no authentication — the gateway verifies the order against its own map, but
it does not check that the robot exists before publishing.

`--map` is the single biggest quality lever for generation: without it the
model has no real node ids and will invent plausible-looking ones. The server
binds to `127.0.0.1` by default because it has no authentication.

## The language

Every name is a **quoted string**, so real identifiers — `pumpenhaus_1`,
`MONTAGE`, `plant-b/l1`, `RK-AM` — are legal without reserving a single
keyword. Modifier clauses parse in any order. Keywords are case-insensitive
(`NODE` and `node` are the same).

Comments are `#`, `--`, and `/* … */`.

### Header

```robotdsl
robot "acme" "AMR-001"      # manufacturer, serialNumber
map "plant-b"               # default mapId for node positions
version 3.0.0               # must match the compiler's target
header 42                   # starting headerId (optional)
timestamp "2026-11-13T12:00:00.000Z"
```

`robot`, `map`, `header`, `timestamp` and `version` are all optional; the CLI
supplies defaults for whatever the file leaves out. A file's own declarations
win over CLI defaults.

### Orders

An order is a route of nodes joined by edges. `route` and `base` both mean
`released: true`; `horizon` means `released: false`.

```robotdsl
order "order-pallet-1" update 0 describe "KLT palletizing run" {
  base {
    node "RK-AM" describe "rack aisle marker" at (12.5, 3.0) facing 0.0 {
      action "pick" blocking HARD describe "grab pallet" with {
        loadId = "KLT-42"
        loadType = "EPAL"
      }
    }
    edge "e-1" describe "main aisle" speed 0.8 length 14.2
    node "CHG-01" describe "conveyor A drop point" at (0.0, 0.0) facing 1.5708 {
      action "drop" blocking HARD with { loadId = "KLT-42" }
    }
  }
  horizon {
    go to "ST-07" at (7.0, 1.0) via "e-2" speed 0.5 {
      action "initPosition" describe "localise before the next pick"
    }
  }
}
```

`go to <node>` is sugar for an edge followed by a node, and accepts both node
and edge modifiers plus `via <edgeId>` to name the connecting edge. Nodes and
edges may omit their action block entirely when they carry none.

**Node modifiers:** `describe`, `at (x, y)` or `at (x, y, theta)`, `facing θ`,
`on map <id>`, `deviation (a, b, theta)`, `deviation_theta <rad>`

**Edge modifiers:** `describe`, `speed`, `maxheight`, `minloadheight`,
`orientation`, `orientation_type global|tangential`, `direction`, `reachbefore`,
`maxrotation`, `trajectory`, `length`, `corridor`

**Action modifiers:** `blocking none|soft|single|hard`, `describe`, `retriable`,
`with { key = value, … }` (values may be strings, numbers, booleans or arrays)

### Instant actions

Each `instant` block becomes one `instantActions` message.

```robotdsl
instant "pause-fleet" {
  action "startPause"
  action "stateRequest"
}
```

### Zones

```robotdsl
zoneset "zs-floor1" on map "plant-b" describe "Floor 1 navigation constraints" {
  zone "welding-corner" describe "welding cell, no entry" blocked {
    polygon (0, 0) (5, 0) (5, 5) (0, 5)
  }

  zone "pedestrian-zone" speed_limit 0.25 {
    polygon (20, 0) (26, 0) (26, 6) (20, 6)
  }

  zone "hazard-entry" describe "sound the beacon through the hazard area" action {
    entry { action "beaconOn" describe "start the beacon" }
    during { action "beaconOn" }
    exit { action "beaconOff" }
    polygon (28, 0) (34, 0) (34, 6) (28, 6)
  }

  zone "prefer-left-lane" priority factor 0.8 {
    polygon (36, 0) (40, 0) (40, 6) (36, 6)
  }

  zone "wet-floor" penalty factor 0.9 {
    polygon (42, 0) (46, 0) (46, 6) (42, 6)
  }

  zone "flow-north" directed heading 0.0 strictness restricted {
    polygon (48, 0) (52, 0) (52, 12) (48, 12)
  }

  zone "two-way-lane" bidirected heading 1.5708 strictness soft {
    polygon (54, 0) (58, 0) (58, 12) (54, 12)
  }
}
```

| zone type | extra clause |
|---|---|
| `blocked` | — |
| `line_guided` | — |
| `release` | — |
| `coordinated_replanning` | — |
| `speed_limit` | `<speed>` |
| `action` | `entry`/`during`/`exit` groups |
| `priority` | `factor <0.0–1.0>` |
| `penalty` | `factor <0.0–1.0>` |
| `directed` | `heading <rad>` `strictness soft\|restricted\|strict` |
| `bidirected` | `heading <rad>` `strictness soft\|restricted` |

A zone's brace block always holds its `polygon` (at least three vertices); an
`action` zone additionally holds its three action groups, which the schema
requires alongside the vertices.

---

## What the compiler fills in

This is the point of the DSL. None of the following is written by the operator:

| field | rule |
|---|---|
| `headerId` | allocated per topic, incremented by one per message |
| `timestamp` | ISO 8601 with milliseconds, or pinned in the file |
| `version` | `3.0.0`, the compiler's target |
| `sequenceId` | traversal index, so nodes land on even and edges on odd values |
| `actionId` | `<actionType slug>-<n>`, unique within the message and stable across runs |
| `edgeId` | `edge-<sequenceId>` when the operator did not name the edge |
| `mapId` | inherited from the file-level `map`, overridable per node |
| `blockingType` | `HARD` for order actions, `NONE` for instant and zone actions |

## Validation

Three layers, and a message is never written unless all three pass:

1. **Parsing** — shape, with line and column in the error.
2. **Semantic** — `RobotDSL.Validate`, the rules that are easy to get wrong:
   - an instant action's `blockingType` must be `NONE`
   - a zone polygon needs at least three vertices
   - `PRIORITY`/`PENALTY` factors must be within `[0.0, 1.0]`
   - a route must start with a node and alternate node, edge, node, …
   - a node with a position must be able to resolve a `mapId`
3. **Schema** — every emitted message is checked against the official v3.0.0
   JSON Schema vendored in `schemas/vda5050/3.0.0`.

The schema check uses a small draft-2020-12 validator written for this project
(`RobotDSL.Schema`). It implements exactly the keyword subset those eight
schemas use — `type`, `required`, `properties`, `items`, `enum`, `const`,
`minimum`, `maximum`, `exclusiveMinimum`, `minItems`, `allOf`, `if`/`then`/
`else`, local `$ref`, and `format: date-time` — so the test suite needs no
external validator.

```bash
robotdsl check <file.robot>                       # parse + semantic only
robotdsl compile <file.robot> --out DIR           # also emit + schema-check
robotdsl compile <file.robot>                     # print to stdout
robotdsl compile <file.robot> --kind zoneSet      # filter by message kind
```

Exit code is 0 only when everything passed.

### Independent cross-check

`tools/verify-output.py` re-implements the critical v3.0.0 invariants in Python
— required fields, the `sequenceId` even/odd rule, the `blockingType` enums,
per-`zoneType` payload requirements, actionId uniqueness, the ISO 8601
timestamp shape, and the absence of v2 field names. It exists so the emitted
JSON is checked by two independent implementations rather than one:

```bash
robotdsl compile examples/palletizing.robot --out out/
python3 tools/verify-output.py out/     # 274 checks
```

It reports a non-zero exit on the first violation, so it drops into CI as-is.

## CLI reference

| flag | meaning |
|---|---|
| `--out DIR` | write one JSON file per message (default: stdout) |
| `--kind K` | only emit `order`, `instantActions` or `zoneSet` |
| `--manufacturer M` / `--serial-number S` | target robot |
| `--header-id N` | first `headerId` to allocate |
| `--timestamp ISO` | timestamp for every message (default: now, UTC) |
| `--schema-dir DIR` | where the v3.0.0 schemas live |
| `--no-validate` | skip schema validation |

Each written file is echoed with the MQTT topic it belongs on, e.g.
`vda5050/v3/acme/AMR-001/order`, so output can be piped straight into a
publisher.

## Troubleshooting

Three things reliably trip people up on a first run.

### `robotdsl: command not found`

`cabal build` puts the binary under `dist-newstyle/`, which is not on your
`PATH`. Either call it through cabal, or install it once:

```bash
cabal run -v0 robotdsl -- check examples/palletizing.robot

# or, permanently:
cabal install exe:robotdsl --installdir ~/.local/bin --overwrite-policy=always
robotdsl check examples/palletizing.robot
```

If you copied the binary out of `dist-newstyle/` by hand instead, remember that
it will not track later rebuilds.

### `cannot read './example/control.robot'`

The directory is `examples`, plural:

```bash
robotdsl check ./examples/control.robot     # correct
robotdsl check ./example/control.robot      # cannot read ...
```

A missing or unreadable input file is reported as a one-line error with exit
code 1.

### `warning: schema directory schemas/vda5050/3.0.0 not found`

`compile` resolves `--schema-dir` **relative to the current directory**, and its
default is `schemas/vda5050/3.0.0`. Run it from the project root, or pass an
absolute path:

```bash
robotdsl compile my.robot --schema-dir "$PWD/schemas/vda5050/3.0.0"
```

The warning means schema validation was skipped — the message is still emitted,
just unchecked. `check` never needs the schemas and works from anywhere.

## Layout

```
src/RobotDSL/
  Version.hs    pinned protocol version + MQTT topic layout
  AST.hs        the surface syntax, with optionals left as optionals
  Parser.hs     text -> AST (megaparsec)
  Validate.hs   semantic rules, one Issue per problem
  Emit.hs       AST -> VDA 5050 JSON, owns all mandatory bookkeeping
  Schema.hs     draft-2020-12 validator for the vendored schemas
agent-src/RobotDSL/Agent/
  Context.hs    map JSON -> node and action vocabulary
  Prompt.hs     system prompt and output cleaning
  Client.hs     OpenRouter (OpenAI-compatible) call
  Loop.hs       generate -> parse -> validate -> retry
  Server.hs     wai application and routes
app/Main.hs     the robotdsl CLI
app/AgentMain.hs  the robotdsl-agent entry point
web/            the browser UI, no build step
tools/stt/      Swift voice helper plus build.sh
test/           parser, emitter, schema and agent tests
examples/       three worked examples
schemas/        the official v3.0.0 JSON Schemas
```

`AST.hs` deliberately keeps optional fields optional and defaults nothing, so
that `Emit.hs` is the single place where the standard's bookkeeping is decided.
`Emit.hs` also never second-guesses the source: whatever `blockingType` the
program says is what gets emitted, which is why the context-dependent rules
live in `Validate.hs` and run first.

## v3.0.0 traps this handles

- `blockingType` on an **instant action** is restricted to `"NONE"` by the
  schema. Order actions default to `HARD`; instant and zone actions default to
  `NONE`. Writing `blocking HARD` in an `instant` block is an error, not a
  silent rejection later.
- v3 renamed `header` to `headerId` and replaced `edge.rotationAllowed` with
  `edge.reachOrientationBeforeEntering` (with inverted meaning). The emitter
  writes the v3 names.
- The official `zoneSet.schema` spells the property definition
  `"priorityFactor "` with a trailing space, while its `required` list uses
  `"priorityFactor"`. The emitter writes the clean name, which is what the
  schema actually checks.
- `sequenceId` is shared between nodes and edges and must alternate, which is
  what makes an order updatable.
- The official schemas ship with trailing-comma syntax errors in three files;
  the copies vendored here are repaired, as recorded in the upstream project's
  `PATCHES.md`.

## Tests

```bash
cabal test
```

139 tests across groups for parsing (including that `speed` and `speed_limit`
do not collide, and that every `zoneType` parses), emitting (sequenceId parity,
actionId uniqueness and stability, headerId allocation, `mapId` inheritance,
the `priorityFactor` key), schema validation (every example round-trips
through the real schemas, plus negative cases that prove the validator actually
rejects: too few vertices, a missing required property, an out-of-range number,
a `SPEED_LIMIT` zone with no `maximumSpeed`, an instant action with
`blockingType: "HARD"`, and an ill-formed timestamp), the fleet client, the
map preview, the generate-parse-validate-retry loop, the agent's HTTP
surface, order planning and rejection rules, and dry-run-first gateway dispatch
(both orders and instant actions).

### Browser tests

The agent's web UI is covered separately, because the questions it answers —
does a label land on another node, is anything clipped once a real font has
measured it, does a generated mission reach the map as a drawn route — need a
browser that can measure and click.

```bash
npm install                 # once; playwright is a devDependency
npx playwright install chromium   # once; downloads the browser

cabal run robotdsl-agent -- --port 8790 --fleet http://127.0.0.1:8080
node tools/browser-test.js

# Dispatch tests use an in-process gateway stub; no broker or robot is needed.
# To publish for real, start the agent with --fleet and --allow-dispatch.
```

Playwright is not part of the Haskell build: the library, the CLI and the
agent are built by cabal alone, so a JS dependency cannot break them.
`node_modules` and the lockfile are ignored.

Fleet-dependent checks are skipped rather than failed when no `--fleet` is
given, because the map alone is a supported way to run. The end-to-end check
spends a real LLM call, so it needs `OPENROUTER_API_KEY`.

## Licence

BSD 3-Clause. See `LICENSE`.
