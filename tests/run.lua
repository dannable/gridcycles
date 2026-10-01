-- tests/run.lua
-- Minimal zero-dependency test runner. Run from the repo root:
--   lua tests/run.lua
-- Works on Lua 5.2-5.4. Production code must still stick to Lua 5.2 (TTS/MoonSharp).
--
-- Add new test files to TEST_FILES below. Each file calls describe()/it().

local TEST_FILES = {
  "tests/test_smoke.lua",
  "tests/test_geom.lua",
  "tests/test_rules.lua",
}

-- Load source modules (they define globals: Config, Geom, Rules)
dofile("src/config.lua")
dofile("src/geom.lua")
dofile("src/rules.lua")

local passed, failed, pending = 0, 0, 0
local failures = {}
local prefix = {}

function describe(name, fn)
  table.insert(prefix, name)
  fn()
  table.remove(prefix)
end

function it(name, fn)
  local full = table.concat(prefix, " > ") .. " > " .. name
  if fn == nil then
    pending = pending + 1
    print("  PENDING " .. full)
    return
  end
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    table.insert(failures, full .. "\n      " .. tostring(err))
  end
end

function pending_it(name) it(name, nil) end

function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "assert_eq") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
  end
end

function assert_near(actual, expected, tol, msg)
  tol = tol or 1e-6
  if math.abs(actual - expected) > tol then
    error((msg or "assert_near") .. ": expected " .. tostring(expected)
      .. " +/- " .. tostring(tol) .. ", got " .. tostring(actual), 2)
  end
end

function assert_true(v, msg)
  if not v then error(msg or "expected true", 2) end
end

function assert_false(v, msg)
  if v then error(msg or "expected false", 2) end
end

for _, f in ipairs(TEST_FILES) do
  print(f)
  dofile(f)
end

print(string.format("\n%d passed, %d failed, %d pending", passed, failed, pending))
for _, msg in ipairs(failures) do print("  FAIL " .. msg) end
os.exit(failed == 0 and 0 or 1)
