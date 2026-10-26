-- keymap service: IPC target for the Mod+K compositor keybind.
-- `noctalia msg panel-toggle mortalglitch/keymap:keymap` (the documented CLI
-- route) reports "unknown panel" for this plugin panel in current Noctalia
-- builds — the CLI toggle path diverges from the in-process one. So the
-- keybind dispatches an event here and we toggle the panel in-process,
-- which reliably opens it.
function onIpc(event, _payload)
  if event == "toggle" then
    noctalia.togglePanel("mortalglitch/keymap:keymap")
  end
end
