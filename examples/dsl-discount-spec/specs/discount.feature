Scenario: Valid code above minimum applies the discount
  Given cart_total 120.00
  And code "SAVE20"
  When discount is applied
  Then applied is true
  And final_total is 96.00

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
