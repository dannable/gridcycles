describe("config", function()
  it("defines 5 gears with tile geometry", function()
    assert_eq(Config.gears.max, 5)
    for g = Config.gears.min, Config.gears.max do
      assert_true(Config.tiles[g] ~= nil, "missing tiles for gear " .. g)
      assert_true(Config.tiles[g].straight > 0)
    end
  end)

  it("tile length increases with gear", function()
    for g = 2, Config.gears.max do
      assert_true(Config.tiles[g].straight > Config.tiles[g - 1].straight)
    end
  end)
end)

describe("modules", function()
  it("Geom and Rules are loaded", function()
    assert_true(type(Geom) == "table")
    assert_true(type(Rules) == "table")
  end)
end)
