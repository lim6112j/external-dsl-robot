#!/usr/bin/env python3
"""Independent cross-check of emitted VDA 5050 v3.0.0 messages.

Deliberately re-implements the critical invariants from the standard rather
than reusing the Haskell validator, so a bug in one is unlikely to be mirrored
in the other.
"""
import json
import sys
from pathlib import Path

ORDER_REQUIRED = ["headerId", "timestamp", "version", "manufacturer",
                  "serialNumber", "orderId", "orderUpdateId", "nodes", "edges"]
NODE_REQUIRED = ["nodeId", "sequenceId", "released", "actions"]
EDGE_REQUIRED = ["edgeId", "sequenceId", "released", "actions"]
ACTION_REQUIRED = ["actionId", "actionType", "blockingType"]
BLOCKING = {"NONE", "SOFT", "SINGLE", "HARD"}
ZONE_TYPES = {"BLOCKED", "LINE_GUIDED", "RELEASE", "COORDINATED_REPLANNING",
              "SPEED_LIMIT", "ACTION", "PRIORITY", "PENALTY",
              "DIRECTED", "BIDIRECTED"}
LIMITATION = {"SOFT", "RESTRICTED", "STRICT"}
SOFT_LIMITATION = {"SOFT", "RESTRICTED"}

failures = []
checks = 0


def check(cond, msg):
    global checks
    checks += 1
    if not cond:
        failures.append(msg)


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def check_action(a, where, allowed_blocking):
    for k in ACTION_REQUIRED:
        check(k in a, f"{where}: action missing {k}")
    check(a.get("blockingType") in allowed_blocking,
          f"{where}: blockingType {a.get('blockingType')!r} not in {allowed_blocking}")
    for p in a.get("actionParameters", []):
        check("key" in p and "value" in p, f"{where}: bad actionParameter {p}")


def check_common(m, where):
    for k in ["headerId", "timestamp", "version", "manufacturer", "serialNumber"]:
        check(k in m, f"{where}: missing {k}")
    check(isinstance(m.get("headerId"), int), f"{where}: headerId not an integer")
    check(m.get("version") == "3.0.0", f"{where}: version is {m.get('version')!r}")
    # ISO 8601 with milliseconds and Z
    ts = m.get("timestamp", "")
    check(len(ts) == 24 and ts[4] == "-" and ts[10] == "T" and ts[-1] == "Z"
          and ts[19] == ".",
          f"{where}: timestamp {ts!r} is not YYYY-MM-DDTHH:MM:SS.fffZ")


def check_order(m, where):
    for k in ORDER_REQUIRED:
        check(k in m, f"{where}: missing {k}")
    check_common(m, where)
    check(isinstance(m.get("orderUpdateId"), int) and m["orderUpdateId"] >= 0,
          f"{where}: orderUpdateId must be a non-negative integer")

    seqs = []
    ids = []
    for n in m.get("nodes", []):
        for k in NODE_REQUIRED:
            check(k in n, f"{where}: node missing {k}")
        check(isinstance(n.get("released"), bool), f"{where}: released not a boolean")
        p = n.get("nodePosition")
        if p is not None:
            for k in ["x", "y", "mapId"]:
                check(k in p, f"{where}: nodePosition missing {k}")
            if "theta" in p:
                check(-3.14159265359 <= p["theta"] <= 3.14159265359,
                      f"{where}: theta {p['theta']} out of range")
        for a in n.get("actions", []):
            check_action(a, f"{where} node {n.get('nodeId')}", BLOCKING)
            ids.append(a["actionId"])
        seqs.append(n["sequenceId"])

    for e in m.get("edges", []):
        for k in EDGE_REQUIRED:
            check(k in e, f"{where}: edge missing {k}")
        check(isinstance(e.get("released"), bool), f"{where}: released not a boolean")
        check("rotationAllowed" not in e,
              f"{where}: v2 field rotationAllowed must not appear")
        for a in e.get("actions", []):
            check_action(a, f"{where} edge {e.get('edgeId')}", BLOCKING)
            ids.append(a["actionId"])
        seqs.append(e["sequenceId"])

    # sequenceId is shared and defines traversal order; nodes even, edges odd.
    all_steps = sorted(
        [(n["sequenceId"], "node") for n in m.get("nodes", [])]
        + [(e["sequenceId"], "edge") for e in m.get("edges", [])])
    check([s for s, _ in all_steps] == list(range(len(all_steps))),
          f"{where}: sequenceIds are not 0..n-1 in traversal order: {all_steps}")
    for s, kind in all_steps:
        check((s % 2 == 0) == (kind == "node"),
              f"{where}: sequenceId {s} on a {kind} breaks the even/odd rule")

    # actionIds must be unique within the message.
    check(len(ids) == len(set(ids)), f"{where}: duplicate actionIds {ids}")


def check_instant(m, where):
    for k in ["headerId", "timestamp", "version", "manufacturer",
              "serialNumber", "actions"]:
        check(k in m, f"{where}: missing {k}")
    check_common(m, where)
    ids = []
    for a in m.get("actions", []):
        # v3.0.0 restricts instant-action blockingType to NONE alone.
        check_action(a, where, {"NONE"})
        ids.append(a["actionId"])
    check(len(ids) == len(set(ids)), f"{where}: duplicate actionIds {ids}")


def check_zone(z, where):
    for k in ["zoneId", "zoneType", "vertices"]:
        check(k in z, f"{where}: zone missing {k}")
    t = z.get("zoneType")
    check(t in ZONE_TYPES, f"{where}: unknown zoneType {t!r}")
    check(len(z.get("vertices", [])) >= 3,
          f"{where}: zone {z.get('zoneId')} has {len(z.get('vertices', []))} vertices")
    for v in z.get("vertices", []):
        check("x" in v and "y" in v, f"{where}: vertex missing x/y")

    if t == "SPEED_LIMIT":
        check("maximumSpeed" in z, f"{where}: SPEED_LIMIT zone needs maximumSpeed")
    if t == "ACTION":
        for k in ["entryActions", "duringActions", "exitActions"]:
            check(k in z, f"{where}: ACTION zone needs {k}")
            for a in z[k]:
                check_action(a, f"{where} zone {z.get('zoneId')}", BLOCKING)
    if t == "PRIORITY":
        check("priorityFactor" in z, f"{where}: PRIORITY zone needs priorityFactor")
        check(0.0 <= z["priorityFactor"] <= 1.0, f"{where}: priorityFactor out of range")
    if t == "PENALTY":
        check("penaltyFactor" in z, f"{where}: PENALTY zone needs penaltyFactor")
        check(0.0 <= z["penaltyFactor"] <= 1.0, f"{where}: penaltyFactor out of range")
    if t == "DIRECTED":
        check("direction" in z and "limitation" in z,
              f"{where}: DIRECTED zone needs direction and limitation")
        check(z.get("limitation") in LIMITATION,
              f"{where}: DIRECTED limitation {z.get('limitation')!r} invalid")
    if t == "BIDIRECTED":
        check("direction" in z and "limitation" in z,
              f"{where}: BIDIRECTED zone needs direction and limitation")
        check(z.get("limitation") in SOFT_LIMITATION,
              f"{where}: BIDIRECTED limitation {z.get('limitation')!r} invalid")


def check_zoneset(m, where):
    for k in ["headerId", "timestamp", "version", "manufacturer",
              "serialNumber", "zoneSet"]:
        check(k in m, f"{where}: missing {k}")
    check_common(m, where)
    zs = m.get("zoneSet", {})
    for k in ["mapId", "zoneSetId", "zones"]:
        check(k in zs, f"{where}: zoneSet missing {k}")
    ids = [z.get("zoneId") for z in zs.get("zones", [])]
    check(len(ids) == len(set(ids)), f"{where}: duplicate zoneIds {ids}")
    for z in zs.get("zones", []):
        check_zone(z, f"{where} zone {z.get('zoneId')}")


def main():
    out = Path(sys.argv[1])
    files = sorted(out.glob("*.json"))
    if not files:
        print(f"no JSON files in {out}")
        return 1
    seen_kinds = set()
    for f in files:
        m = json.loads(f.read_text())
        if "nodes" in m and "edges" in m:
            seen_kinds.add("order")
            check_order(m, f.name)
        elif "actions" in m:
            seen_kinds.add("instantActions")
            check_instant(m, f.name)
        elif "zoneSet" in m:
            seen_kinds.add("zoneSet")
            check_zoneset(m, f.name)
        else:
            failures.append(f"{f.name}: unrecognised message shape")
        print(f"  {f.name}")

    # Per-message invariants only. Whether all three kinds are present depends
    # on the source file, which this script does not read.

    print(f"\n{checks} checks, {len(failures)} failure(s)")
    for f in failures:
        print(f"  FAIL {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
