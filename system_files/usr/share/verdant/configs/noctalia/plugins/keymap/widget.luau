-- keymap bar widget: keyboard glyph that opens the Shortcuts panel.
function update()
  barWidget.setGlyph("keyboard")
  barWidget.setTooltip("Shortcuts & hotkeys (Keymap)")
end

function onClick()
  noctalia.togglePanel("mortalglitch/keymap:keymap")
end

-- IPC target for the Mod+K compositor keybind:
-- `noctalia msg plugin mortalglitch/keymap:keys focused toggle`
-- (the CLI `panel-toggle <plugin:panel>` route reports "unknown panel"
-- for plugin panels, so the keybind dispatches here and we toggle
-- in-process).
function onIpc(event, _payload)
  if event == "toggle" then
    noctalia.togglePanel("mortalglitch/keymap:keymap")
  end
end

