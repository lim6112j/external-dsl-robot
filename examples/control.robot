# Operator controls. Each `instant` block becomes one instantActions message.
#
# Note there is no `blocking` clause anywhere: VDA 5050 v3.0.0 restricts the
# blockingType of an instant action to "NONE", so the compiler defaults to it
# and rejects any other value.

robot "acme" "AMR-001"

instant "pause-fleet" {
  action "startPause"
  action "stateRequest"
}

instant "resume" {
  action "stopPause"
}

instant "abort" {
  action "cancelOrder" describe "operator abort"
}
