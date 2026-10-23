-- keymap bar widget: keyboard glyph that opens the Shortcuts panel.
function update()
  barWidget.setGlyph("keyboard")
  barWidget.setTooltip("Shortcuts & hotkeys (Keymap)")
end

function onClick()
  noctalia.togglePanel("mortalglitch/keymap:keymap")
end
