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

## Build

```bash
cabal build          # library + CLI
cabal test           # 41 tests
```

Requires GHC 9.10 (developed against 9.10.3) and cabal. Dependencies: `aeson`,
`megaparsec`, `text`, `containers`, `time`.

```bash
cabal run robotdsl -- check examples/palletizing.robot
cabal run robotdsl -- compile examples/palletizing.robot --out out/
```

The binary is not put on your `PATH` by `cabal build`. See
[Troubleshooting](#troubleshooting) for how to run it either way, and note that
`compile` resolves its schema directory relative to the current directory.

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
app/Main.hs     CLI
test/           parser, emitter and schema tests
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

41 tests across three groups: parsing (including that `speed` and `speed_limit`
do not collide, and that every `zoneType` parses), emitting (sequenceId parity,
actionId uniqueness and stability, headerId allocation, `mapId` inheritance,
the `priorityFactor` key), and schema validation (every example round-trips
through the real schemas, plus negative cases that prove the validator actually
rejects: too few vertices, a missing required property, an out-of-range number,
a `SPEED_LIMIT` zone with no `maximumSpeed`, an instant action with
`blockingType: "HARD"`, and an ill-formed timestamp).

## Licence

BSD 3-Clause. See `LICENSE`.
