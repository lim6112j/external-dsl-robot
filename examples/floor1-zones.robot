# A zoneSet for floor 1 of plant-b, exercising every zoneType in the standard.
# Zones are how v3.0.0 lets fleet control constrain navigation without changing
# the map itself.

robot "acme" "AMR-001"
map "plant-b"

zoneset "zs-floor1" on map "plant-b" describe "Floor 1 navigation constraints" {
  zone "welding-corner" describe "welding cell, no entry" blocked {
    polygon (0, 0) (5, 0) (5, 5) (0, 5)
  }

  zone "main-aisle" describe "keep robots on the marked line" line_guided {
    polygon (5, 0) (7, 0) (7, 30) (5, 30)
  }

  zone "narrow-passage" describe "needs an explicit release from fleet control" release {
    polygon (10, 2) (11, 2) (11, 4) (10, 4)
  }

  zone "cross-dock" describe "robots must replan around each other" coordinated_replanning {
    polygon (12, 2) (18, 2) (18, 8) (12, 8)
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

  zone "wet-floor" describe "only traverse if there is no alternative" penalty factor 0.9 {
    polygon (42, 0) (46, 0) (46, 6) (42, 6)
  }

  zone "flow-north" directed heading 0.0 strictness restricted {
    polygon (48, 0) (52, 0) (52, 12) (48, 12)
  }

  zone "two-way-lane" bidirected heading 1.5708 strictness soft {
    polygon (54, 0) (58, 0) (58, 12) (54, 12)
  }
}
