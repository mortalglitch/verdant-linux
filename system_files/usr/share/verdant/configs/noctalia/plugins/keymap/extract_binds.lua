-- extract_binds.lua — bundled with the keymap plugin.
-- Evaluates the Hyprland Lua config's binds with a mocked hl API and emits a
-- JSON array of {chord, description, category}. Runs standalone (no Hyprland).
-- Usage: luajit extract_binds.lua [path-to-binds.lua]

local bindsPath = arg and arg[1] or nil
if not bindsPath then
  local home = os.getenv("HOME") or ""
  local xcfg = os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")
  local candidates = {
    xcfg .. "/hypr/config/binds.lua",
    home .. "/.config/hypr/config/binds.lua",
  }
  for _, c in ipairs(candidates) do
    local f = io.open(c, "r")
    if f then bindsPath = c; f:close() break end
  end
end

local function jesc(s)
  s = tostring(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return s
end

local noctaliaNames = {
  ["panel-toggle launcher"] = "Open app launcher",
  ["panel-toggle session"] = "Open session menu",
  ["panel-toggle clipboard"] = "Open clipboard history",
  ["panel-toggle wallpaper"] = "Open wallpaper panel",
  ["panel-toggle control-center"] = "Open control center",
  ["settings toggle"] = "Open settings",
  ["screenshot-fullscreen pick"] = "Screenshot (pick monitor)",
  ["screenshot-fullscreen"] = "Screenshot (all)",
  ["screenshot-region"] = "Screenshot region",
  ["volume-up"] = "Volume up",
  ["volume-down"] = "Volume down",
  ["volume-mute"] = "Mute audio",
  ["mic-mute"] = "Mute microphone",
  ["media toggle"] = "Media play / pause",
  ["media next"] = "Media next track",
  ["media previous"] = "Media previous track",
  ["brightness-up"] = "Brightness up",
  ["brightness-down"] = "Brightness down",
}

local function fmtArgs(args)
  local parts = {}
  for i, a in ipairs(args) do
    if type(a) == "table" then
      local kv = {}
      for k, v in pairs(a) do kv[#kv + 1] = k .. "=" .. tostring(v) end
      table.sort(kv)
      parts[#parts + 1] = table.concat(kv, ", ")
    else
      parts[#parts + 1] = tostring(a)
    end
  end
  return table.concat(parts, " ")
end

local function describeExec(cmd)
  cmd = tostring(cmd)
  if cmd:find("ocr-region") then return "OCR region (copy text)" end
  local sub = cmd:match("noctalia%s+msg%s+(.+)$")
  if sub then
    return noctaliaNames[sub] or ("Noctalia: " .. sub)
  end
  local app = cmd:match("uwsm%s+app%s+--%s*(.+)$")
  if app then return "Open " .. app end
  return "Run " .. cmd
end

local function describeAction(action)
  if type(action) ~= "table" or not action.__type then
    return "Bound"
  end
  local t, args = action.__type, action.__args or {}
  if t == "exec" or t == "exec_cmd" then
    return describeExec(args[1])
  end
  local a1 = args[1]
  local tbl = type(a1) == "table" and a1 or {}
  if t == "window.kill" then return "Kill window" end
  if t == "window.close" then return "Close window" end
  if t == "window.float" then return "Toggle floating" end
  if t == "window.pseudo" then return "Toggle pseudo-tiling" end
  if t == "window.drag" then return "Drag window" end
  if t == "window.fullscreen" then
    if tbl.mode == "fullscreen" then return "Toggle fullscreen" end
    return "Toggle maximize"
  end
  if t == "window.resize" then
    local d = {}
    if (tbl.x or 0) > 0 then d[#d+1] = "right" elseif (tbl.x or 0) < 0 then d[#d+1] = "left" end
    if (tbl.y or 0) > 0 then d[#d+1] = "down" elseif (tbl.y or 0) < 0 then d[#d+1] = "up" end
    return "Resize window " .. table.concat(d, "+")
  end
  if t == "window.move" then
    local ws = tbl.workspace
    if ws == "special:magic" or ws == "magic" then
      return "Move window to scratchpad"
    end
    local extra = (tbl.follow == false) and " (stay put)" or ""
    return "Move window to workspace " .. tostring(ws) .. extra
  end
  if t == "focus" then
    if tbl.direction then return "Focus window " .. tbl.direction end
    if tbl.workspace then
      local ws = tbl.workspace
      if ws == "e+1" then return "Next workspace (wheel)" end
      if ws == "e-1" then return "Previous workspace (wheel)" end
      return "Switch to workspace " .. tostring(ws)
    end
  end
  if t == "layout" then return "Toggle layout: " .. tostring(args[1]) end
  if t == "workspace.toggle_special" then
    return "Toggle scratchpad (" .. tostring(args[1]) .. ")"
  end
  return t .. " (" .. fmtArgs(args) .. ")"
end

local function categorize(action)
  if type(action) == "table" and (action.__type == "exec" or action.__type == "exec_cmd") then
    local cmd = tostring(action.__args and action.__args[1] or "")
    if cmd:find("noctalia") then return "Noctalia" end
  end
  return "Hyprland"
end

local function marker(name, args) return { __type = name, __args = args } end

local window = setmetatable({}, {
  __index = function(_, m) return function(...) return marker("window." .. m, {...}) end end
})
local workspace = setmetatable({}, {
  __index = function(_, m) return function(...) return marker("workspace." .. m, {...}) end end
})
local dsp = setmetatable({ window = window, workspace = workspace }, {
  __index = function(_, m) return function(...) return marker(m, {...}) end end
})

local captured = {}
local function newBindObject()
  local b = { enabled = true }
  b.set_enabled = function(self, v) self.enabled = v end
  b.set_disabled = function(self, v) self.enabled = not v end
  return b
end

_G.hl = {
  bind = function(key, action, opts)
    captured[#captured + 1] = { chord = tostring(key), action = action, opts = opts }
    return newBindObject()
  end,
  dsp = dsp,
}

_G.terminal = "ghostty"
_G.fileManager = "nautilus"
_G.browser = "brave-browser"
_G.ipc = "noctalia msg "
_G.launchPrefix = "uwsm app -- "
_G.mainMod = "SUPER"

local ok, err
if bindsPath and io.open(bindsPath, "r") then
  ok, err = pcall(dofile, bindsPath)
  if not ok then
    io.stderr:write("ERR evaluating " .. bindsPath .. ": " .. tostring(err) .. "\n")
    print("[]")
    os.exit(1)
  end
else
  io.stderr:write("ERR: binds file not found: " .. tostring(bindsPath) .. "\n")
  print("[]")
  os.exit(1)
end

local out = {}
for _, b in ipairs(captured) do
  local chord = tostring(b.chord):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  out[#out + 1] = string.format(
    '{"chord":"%s","description":"%s","category":"%s"}',
    jesc(chord), jesc(describeAction(b.action)), jesc(categorize(b.action))
  )
end
print("[" .. table.concat(out, ",") .. "]")
