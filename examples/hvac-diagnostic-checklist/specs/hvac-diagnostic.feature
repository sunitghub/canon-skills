# Derived from Acceptance in .tickets/t-1ff1/acceptance.md — don't hand-edit; edit Acceptance instead.
#
# Three rule shapes, one per field type on the source diagnostic checklist:
#   breaker    — installed amps vs required amps
#   RLA        — actual running load amps vs a component's max RLA rating
#   tolerance  — a measured value vs a target/recommended value within a pinned tolerance
#                (covers superheat and subcooling readings)

Scenario: Installed breaker meets the required rating
  Given required_amps 60
  And installed_amps 60
  When the breaker is checked
  Then compliant is true
  And reason is "breaker meets required rating"

Scenario: Installed breaker below the required rating fails
  Given required_amps 60
  And installed_amps 50
  When the breaker is checked
  Then compliant is false
  And reason is "breaker undersized"

Scenario: Second required/installed pair from the checklist (outdoor unit)
  Given required_amps 40
  And installed_amps 40
  When the breaker is checked
  Then compliant is true
  And reason is "breaker meets required rating"

Scenario: Actual RLA at the max rating is compliant
  Given max_rla 19
  And actual_rla 19
  When the RLA reading is checked
  Then compliant is true
  And reason is "actual RLA within max rating"

Scenario: Actual RLA exceeding the max rating is a fault
  Given max_rla 19
  And actual_rla 22
  When the RLA reading is checked
  Then compliant is false
  And reason is "actual RLA exceeds max rating"

Scenario: Second max/actual RLA pair from the checklist (blower motor)
  Given max_rla 2.6
  And actual_rla 2.6
  When the RLA reading is checked
  Then compliant is true
  And reason is "actual RLA within max rating"

Scenario: Actual reading exactly matches target
  Given target 9
  And actual 9
  And tolerance 3
  When the reading is checked
  Then compliant is true
  And reason is "actual within tolerance of target"

Scenario: Actual reading outside tolerance fails
  Given target 9
  And actual 15
  And tolerance 3
  When the reading is checked
  Then compliant is false
  And reason is "actual outside tolerance of target"

Scenario: Second target/actual pair from the checklist (subcooling)
  Given target 5
  And actual 5
  And tolerance 3
  When the reading is checked
  Then compliant is true
  And reason is "actual within tolerance of target"
