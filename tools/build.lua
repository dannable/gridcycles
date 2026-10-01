-- tools/build.lua
-- Flatten src/Global.lua (resolving "#include name" lines against src/) into one
-- file. Dev tooling only; runs under plain Lua, never inside TTS.
--
--   lua tools/build.lua                 -> writes build/Global.lua
--   lua tools/build.lua <dir>           -> also copies it to <dir>/Global.-1.lua
--                                          (the VS Code TTS extension's folder)

local function read(path)
  local f = assert(io.open(path, "rb"), "cannot open " .. path)
  local s = f:read("a")
  f:close()
  return s
end

local function write(path, s)
  local f = assert(io.open(path, "wb"), "cannot write " .. path)
  f:write(s)
  f:close()
end

local seen = {}

local function expand(name)
  if seen[name] then return "" end
  seen[name] = true
  local src = read("src/" .. name .. ".lua")
  local out = {}
  for line in (src .. "\n"):gmatch("(.-)\r?\n") do
    local inc = line:match("^#include%s+(%S+)")
    if inc then
      out[#out + 1] = expand(inc)
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

local flat = expand("Global")
os.execute('mkdir build 2>nul')
write("build/Global.lua", flat)
print("wrote build/Global.lua (" .. #flat .. " bytes)")

local dest = arg[1]
if dest then
  write(dest .. "/Global.-1.lua", flat)
  write(dest .. "/Global.-1.xml", read("ui/Global.xml"))
  print("copied Global.-1.lua and Global.-1.xml to " .. dest)
end
