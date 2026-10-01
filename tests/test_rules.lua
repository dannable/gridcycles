-- M1: replace each pending_it with a real it() as Rules is implemented.
-- Use a fixed rollFn, e.g. function() return 4 end, for determinism.
describe("Rules.resolveMove", function()
  pending_it("shift clamps to gear range and maxShift")
  pending_it("curve succeeds when roll >= gear")
  pending_it("failed curve goes straight")
  pending_it("spin-out at high gear curves and drops to gear 1")
  pending_it("crash resets trail, respawns at gear 1, keeps Prizms")
  pending_it("capturing the final Prizm returns outcome 'win'")
end)
