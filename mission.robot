robot "acme" "AMR-001"
map "plant-b/l1"
order "order-1" {
  base {
    node "RK-AM" on map "plant-b/l1" {
      action "pick" describe "grab pallet"
    }
    go to "RK-AE" on map "plant-b/l1"
    go to "AS-1E" on map "plant-b/l1"
    go to "CHG-02" on map "plant-b/l1"
    go to "AS-1E" on map "plant-b/l1"
    go to "RK-AE" on map "plant-b/l1"
    go to "RK-AM" on map "plant-b/l1"
    go to "RK-AW" on map "plant-b/l1"
    go to "AS-1W" on map "plant-b/l1"
    go to "AS-2W" on map "plant-b/l1"
    go to "AS-3W" on map "plant-b/l1"
    go to "AS-4W" on map "plant-b/l1"
    go to "CHG-01" on map "plant-b/l1" {
      action "drop" describe "drop pallet"
    }
  }
}

