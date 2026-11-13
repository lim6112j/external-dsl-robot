# A KLT palletizing run: pick at the rack, drop at conveyor A, then head for
# the next station. Everything the standard demands but the operator should not
# have to type (headerId, timestamp, sequenceId, actionId, edgeId) is filled in
# by the compiler.

robot "acme" "AMR-001"
map "plant-b"
version 3.0.0

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
