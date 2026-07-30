Scenario: Valid code above minimum applies the discount
  Given cart_total 120.00
  And code "SAVE20"
  When discount is applied
  Then applied is true
  And final_total is 96.00
  And reason is "SAVE20 applied"

Scenario: Valid code below minimum is rejected
  Given cart_total 40.00
  And code "SAVE10"
  When discount is applied
  Then applied is false
  And reason is "minimum not met"

Scenario: Unknown code is rejected
  Given cart_total 200.00
  And code "SAVE99"
  When discount is applied
  Then applied is false
  And reason is "invalid code"

# Boundary scenarios (t-ef19) — pin the exact thresholds/rate so they are not left to inference.
# Without these, "40 rejected" only proves SAVE10's min is > 40 (not = 50), and nothing proves
# SAVE10's rate or SAVE20's min — a guessed value would still pass.

Scenario: SAVE10 exactly at its minimum applies at 10 percent
  Given cart_total 50.00
  And code "SAVE10"
  When discount is applied
  Then applied is true
  And final_total is 45.00
  And reason is "SAVE10 applied"

Scenario: SAVE10 one cent below its minimum is rejected
  Given cart_total 49.99
  And code "SAVE10"
  When discount is applied
  Then applied is false
  And reason is "minimum not met"

Scenario: SAVE20 one cent below its minimum is rejected
  Given cart_total 99.99
  And code "SAVE20"
  When discount is applied
  Then applied is false
  And reason is "minimum not met"

Scenario: SAVE20 exactly at its minimum applies at 20 percent
  Given cart_total 100.00
  And code "SAVE20"
  When discount is applied
  Then applied is true
  And final_total is 80.00
  And reason is "SAVE20 applied"
