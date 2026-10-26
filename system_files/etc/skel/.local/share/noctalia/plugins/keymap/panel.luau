-- keymap panel: live list of the user's compositor + Noctalia shortcuts,
-- with a search bar. Re-reads the live keymap every time it's opened.
-- Shows Hyprland binds under Hyprland, Umbriel binds under Umbriel —
-- whichever compositor the session is actually running.

local LUAJIT = "/usr/bin/luajit"
local PYTHON = "python3"
local HYPR_EXTRACTOR = "extract_binds.lua"
local UMBRIEL_EXTRACTOR = "extract_umbriel.py"

local CATEGORY_GLYPHS = {
  Noctalia = "moon",
  Hyprland = "keyboard",
  Umbriel = "aperture",
}

local binds = nil      -- array of { chord, description, category }
local search = ""
local loading = false
local errorMsg = nil
local compositor = nil -- "Hyprland" | "Umbriel" | nil (unknown)

-- Detect the running Wayland compositor. XDG_CURRENT_DESKTOP is set by the
-- session (Hyprland -> "Hyprland", Umbriel -> "umbriel"); fall back to a
-- process check when it's absent (e.g. Noctalia started outside a session).
local function detectCompositor(cb)
  local xd = (noctalia.getenv("XDG_CURRENT_DESKTOP") or ""):lower()
  if xd:find("umbriel") then return cb("Umbriel") end
  if xd:find("hyprland") then return cb("Hyprland") end
  noctalia.processMatches(function(hasHypr)
    if hasHypr then
      cb("Hyprland")
    else
      noctalia.processMatches(function(hasUmb)
        cb(hasUmb and "Umbriel")
      end, "umbriel")
    end
  end, "Hyprland")
end

local function runExtractor()
  loading = true
  errorMsg = nil
  renderList()
  local dir = noctalia.pluginDir()
  local cmd
  if compositor == "Umbriel" then
    cmd = { PYTHON, dir .. "/" .. UMBRIEL_EXTRACTOR }
  else
    -- Hyprland (default when unknown)
    cmd = { LUAJIT, dir .. "/" .. HYPR_EXTRACTOR }
  end
  noctalia.runAsync(cmd, function(result)
    if result.exitCode == 0 then
      local decoded = noctalia.json.decode(result.stdout)
      if type(decoded) == "table" and #decoded > 0 then
        binds = decoded
        noctalia.log("keymap: " .. #binds .. " binds (" .. tostring(compositor or "unknown") .. ")")
      else
        binds = nil
        errorMsg = "Couldn't parse the keymap."
      end
    else
      binds = nil
      errorMsg = "Failed to read keybindings."
      if result.stderr and result.stderr ~= "" then
        noctalia.log("keymap extractor: " .. result.stderr)
      end
    end
    loading = false
    renderList()
  end)
end

local function filterBinds()
  local q = search:lower()
  local out = {}
  if not binds then return out end
  for _, b in ipairs(binds) do
    if q == "" then
      out[#out + 1] = b
    else
      local hay = (b.chord .. " " .. b.description .. " " .. b.category):lower()
      if hay:find(q, 1, true) then
        out[#out + 1] = b
      end
    end
  end
  return out
end

-- Noctalia first, then every other category in first-seen order — so the
-- active compositor (Hyprland or Umbriel) lands below Noctalia without
-- hardcoding which compositor is running.
local function categoryOrder()
  local cats = {}
  local function add(c)
    local seen = false
    for _, x in ipairs(cats) do if x == c then seen = true break end end
    if not seen then cats[#cats + 1] = c end
  end
  local hasNoctalia = false
  for _, b in ipairs(binds or {}) do
    if b.category == "Noctalia" then hasNoctalia = true break end
  end
  if hasNoctalia then add("Noctalia") end
  for _, b in ipairs(binds or {}) do
    if b.category ~= "Noctalia" then add(b.category) end
  end
  return cats
end

local function row(b, idx)
  local chord = b.chord
  return ui.row({
    key = "row-" .. idx,
    gap = 12,
    paddingH = 12,
    paddingV = 7,
    align = "center",
    -- closure: click copies this exact chord
    onClick = function()
      noctalia.copyToClipboard(chord, "text/plain")
    end,
    onHover = function(state, _key)
      -- hover state is cosmetic; the chord is already captured above
    end,
  }, {
    ui.label({
      text = b.chord,
      fontFamily = "monospace",
      fontSize = 13,
      fontWeight = "bold",
      color = b.category == "Noctalia" and "primary" or "on_surface",
      maxWidth = 200,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.label({
      text = b.description,
      fontSize = 12.5,
      color = "on_surface_variant",
      maxWidth = 210,
      maxLines = 2,
      textAlign = "end",
    }),
  })
end

local function sectionHeader(category, count)
  return ui.row({
    key = "hdr-" .. category,
    gap = 8,
    paddingH = 12,
    paddingV = 6,
    align = "center",
  }, {
    ui.glyph({ name = CATEGORY_GLYPHS[category] or "keyboard", size = 14 }),
    ui.label({ text = category, fontSize = 12, fontWeight = "bold" }),
    ui.spacer({ flexGrow = 1 }),
    ui.label({ text = tostring(count), fontSize = 11, color = "on_surface_variant" }),
  })
end

function renderList()
  local filtered = filterBinds()
  local children = {}

  for _, cat in ipairs(categoryOrder()) do
    local catCount = 0
    for _, b in ipairs(filtered) do
      if b.category == cat then catCount = catCount + 1 end
    end
    if catCount > 0 then
      children[#children + 1] = sectionHeader(cat, catCount)
      for _, b in ipairs(filtered) do
        if b.category == cat then
          children[#children + 1] = row(b, #children)
        end
      end
    end
  end

  if loading then
    children[#children + 1] = ui.column({
      gap = 8, paddingV = 24, align = "center", justify = "center",
    }, {
      ui.glyph({ name = "loader", size = 22 }),
      ui.label({ text = "Reading keybindings…", fontSize = 12, color = "on_surface_variant" }),
    })
  elseif errorMsg then
    children[#children + 1] = ui.column({
      gap = 8, paddingV = 24, align = "center", justify = "center",
    }, {
      ui.glyph({ name = "alert-triangle", size = 22 }),
      ui.label({ text = errorMsg, fontSize = 12, color = "error" }),
    })
  elseif #children == 0 then
    children[#children + 1] = ui.column({
      gap = 8, paddingV = 24, align = "center", justify = "center",
    }, {
      ui.glyph({ name = "search", size = 22 }),
      ui.label({
        text = "No shortcuts match “" .. search .. "”",
        fontSize = 12, color = "on_surface_variant",
      }),
    })
  end

  local countLabel = binds and (#filtered .. " / " .. #binds .. " shortcuts") or "—"
  local title = "Shortcuts" .. (compositor and (" · " .. compositor) or "")
  panel.render(ui.column({ gap = 10, padding = 14, flexGrow = 1, align = "stretch", justify = "start" }, {
    ui.row({ gap = 10, align = "center" }, {
      ui.label({ text = title, fontSize = 16, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = countLabel, fontSize = 12, color = "on_surface_variant" }),
      ui.button({
        glyph = "refresh", glyphSize = 14, variant = "ghost",
        tooltip = "Refresh", onClick = "onRefresh",
      }),
    }),
    ui.row({ gap = 8, align = "center", padding = 8, radius = 10, fill = "surface_variant" }, {
      ui.glyph({ name = "search", size = 16, color = "on_surface_variant" }),
      ui.input({
        key = "search",
        placeholder = "Search shortcuts…",
        fontSize = 13,
        focus = true,
        flexGrow = 1,
        onChange = "onSearchChange",
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 4, radius = 10, border = "outline" }, children),
  }))
end

function onSearchChange(value)
  search = value or ""
  renderList()
end

function onRefresh()
  runExtractor()
end

function onOpen(_context)
  search = ""
  binds = nil
  errorMsg = nil
  compositor = nil
  loading = true
  renderList()
  detectCompositor(function(comp)
    compositor = comp
    runExtractor()
  end)
end

function onClose()
  search = ""
end
