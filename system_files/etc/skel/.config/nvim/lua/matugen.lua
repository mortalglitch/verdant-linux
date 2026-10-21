 local M = {}

function M.setup()
  require('base16-colorscheme').setup({
    base00 = '#f9f9f9',
    base01 = '#eeeeee',
    base02 = '#e8e8e8',
    base03 = '#777777',
    base04 = '#474747',
    base05 = '#1b1b1b',
    base06 = '#1b1b1b',
    base07 = '#1b1b1b',
    base08 = '#ba1a1a',
    base09 = '#3b3b3b',
    base0A = '#5e5e5e',
    base0B = '#000000',
    base0C = '#474747',
    base0D = '#474747',
    base0E = '#ababab',
    base0F = '#c6c6c6',
  })

  local hi = function(group, opts)
    vim.api.nvim_set_hl(0, group, opts)
  end

  -- telescope.nvim
  hi('TelescopeNormal',         { fg = '#1b1b1b',          bg = '#f9f9f9' })
  hi('TelescopeBorder',         { fg = '#777777',             bg = '#f9f9f9' })
  hi('TelescopePromptNormal',   { fg = '#1b1b1b',          bg = '#f9f9f9' })
  hi('TelescopePromptBorder',   { fg = '#777777',             bg = '#f9f9f9' })
  hi('TelescopePromptPrefix',   { fg = '#000000',             bg = '#f9f9f9' })
  hi('TelescopePromptCounter',  { fg = '#474747',  bg = '#f9f9f9' })
  hi('TelescopePromptTitle',    { fg = '#f9f9f9',             bg = '#000000' })
  hi('TelescopePreviewTitle',   { fg = '#f9f9f9',             bg = '#5e5e5e' })
  hi('TelescopeResultsTitle',   { fg = '#f9f9f9',             bg = '#3b3b3b' })
  hi('TelescopeSelection',      { fg = '#1b1b1b',          bg = '#e8e8e8' })
  hi('TelescopeSelectionCaret', { fg = '#000000',             bg = '#e8e8e8' })
  hi('TelescopeMatching',       { fg = '#000000',             bold = true })

  -- mini.pick
  hi('MiniPickNormal',         { fg = '#1b1b1b',          bg = '#f9f9f9' })
  hi('MiniPickBorder',         { fg = '#777777',             bg = '#f9f9f9' })
  hi('MiniPickPrompt',   { fg = '#1b1b1b',          bg = '#f9f9f9' })
  hi('MiniPickPromptPrefix',   { fg = '#000000',             bg = '#f9f9f9' })
  hi('MiniPickBorderText',    { fg = '#f9f9f9',             bg = '#000000' })
  hi('MiniPickMatchCurrent',      { fg = '#1b1b1b',          bg = '#e8e8e8' })
  hi('MiniPickPromptCaret', { fg = '#000000',             bg = '#e8e8e8' })
  hi('MiniPickMatchRanges',       { fg = '#000000',             bold = true })
end

-- Register a signal handler for SIGUSR1 (matugen updates).
-- The handler re-requires this module, which re-runs the code below, so the
-- previous handle is stopped first; otherwise handlers double on every signal.
if _G.__matugen_signal then
  _G.__matugen_signal:stop()
  _G.__matugen_signal:close()
end

local signal = vim.uv.new_signal()
_G.__matugen_signal = signal
signal:start(
  'sigusr1',
  vim.schedule_wrap(function()
    package.loaded['matugen'] = nil
    require('matugen').setup()
  end)
)

return M
