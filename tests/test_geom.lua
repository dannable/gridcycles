-- M1: replace each pending_it with a real it() as Geom is implemented.
describe("Geom.segmentsIntersect", function()
  pending_it("crossing segments intersect")
  pending_it("parallel segments do not intersect")
  pending_it("collinear overlapping segments intersect")
  pending_it("segments touching at an endpoint intersect")
end)

describe("Geom.tilePath", function()
  pending_it("straight from origin heading 0 ends at (0, length)")
  pending_it("heading +z: left curve bends toward -x, right toward +x; heading changes by sweep")
  pending_it("curve produces Config.arcSegments segments")
  pending_it("exit pose of tile N equals entry pose of tile N+1")
end)

describe("Geom.pathHitsTrails", function()
  pending_it("ignores the joint with the mover's own previous tile")
  pending_it("detects crossing an opponent trail")
  pending_it("detects crossing your own older trail")
end)

describe("Geom.pathCrossesPrizm", function()
  pending_it("path straight through the Prizm captures it")
  pending_it("path ending mid-Prizm does not capture")
end)

describe("Geom.inBounds", function()
  pending_it("path leaving the mat is out of bounds")
end)
