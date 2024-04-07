local info = os.getenv("WEZTERM_EXECUTABLE")
local nix_test = os.getenv("NIX_PROFILES")
local isMac = info:find("MacOS") ~= nil
local isNix = not (nix_test == nil or nix_text == "")


-- gets basename of path. From https://stackoverflow.com/a/39872872
-- local function basename(str)
--   return str:sub(str:find("/[^/|\\]*$") + 1)
-- end

local wezterm = require("wezterm")
local config = {}

if wezterm.config_builder then
  config = wezterm.config_builder()
end

config.disable_default_key_bindings = true
config.keys = {
  -- Manually add Ctrl+Shift+V for Paste
  {
    key = "v",
    mods = "CTRL|SHIFT",
    action = wezterm.action.PasteFrom("Clipboard"),
  },
  -- Manually add Ctrl+Shift+C for Copy
  {
    key = "c",
    mods = "CTRL|SHIFT",
    action = wezterm.action.CopyTo("Clipboard"),
  },
  -- Create new TMUX window
  {
    key = "t",
    mods = "CTRL",
    action = wezterm.action.SendString("\x01" .. "t"),
  },
  -- Close TMUX window
  {
    key = "w",
    mods = "CTRL",
    action = wezterm.action.SendString("\x01" .. "w"),
  },
  -- Close TMUX window
  {
    key = "o",
    mods = "CTRL",
    action = wezterm.action.SendString("\x01" .. "o"),
  },
}

for i = 1, 9 do
  table.insert(config.keys, {
    key = tostring(i),
    mods = "CTRL",
    action = wezterm.action.SendString("\x01" .. tostring(i)),
  })
end

-- My modifications: https://gist.github.com/RingOfStorms/b2ff0c4e37f5be9f985c72c3ec9a3e62
local scheme = wezterm.get_builtin_color_schemes()["Catppuccin Mocha"]
local c = {
  text = "#e0e0e0",
  subtext1 = "#cccccc",
  subtext0 = "#b8b8b8",
  overlay2 = "#a3a3a3",
  overlay1 = "#8c8c8c",
  overlay0 = "#787878",
  surface2 = "#636363",
  surface1 = "#4f4f4f",
  surface0 = "#3b3b3b",
  base = "#262626",
  mantle = "#1f1f1f",
  crust = "#171717",
}
scheme.foreground = c.text
scheme.background = c.base
scheme.cursor_fg = c.crust
scheme.selection_fg = c.text
scheme.selection_bg = c.surface2
scheme.scrollbar_thumb = c.surface2
scheme.split = c.overlay0
scheme.ansi[1] = c.surface1
scheme.ansi[8] = c.subtext1
scheme.brights[1] = c.surface2
scheme.brights[8] = c.subtext0
scheme.visual_bell = c.surface0
-- I don't use tab bar so not really needed
scheme.tab_bar.background = c.crust
scheme.tab_bar.active_tab.fg_color = c.crust
scheme.tab_bar.inactive_tab.bg_color = c.mantle
scheme.tab_bar.inactive_tab.fg_color = c.text
scheme.tab_bar.inactive_tab_hover.bg_color = c.base
scheme.tab_bar.inactive_tab_hover.fg_color = c.text
scheme.tab_bar.new_tab.bg_color = c.surface0
scheme.tab_bar.new_tab.fg_color = c.text
scheme.tab_bar.new_tab_hover.bg_color = c.surface1
scheme.tab_bar.new_tab_hover.fg_color = c.text
scheme.tab_bar.inactive_tab_edge = c.surface0

config.color_schemes = { ["Catppuccin Coal"] = scheme }
config.color_scheme = "Catppuccin Coal"

if isMac then
  config.font_size = 16
  config.window_decorations = "RESIZE"
elseif isNix then
  config.enable_wayland = true

  config.window_decorations = "NONE"

  -- Fix for cursor disappearing in gnome
  -- https://github.com/wez/wezterm/issues/1742#issuecomment-1075333507
  local xcursor_size = nil
  local xcursor_theme = nil

  local success, stdout, stderr = wezterm.run_child_process({"gsettings", "get", "org.gnome.desktop.interface", "cursor-theme"})
  if success then
    xcursor_theme = stdout:gsub("'(.+)'\n", "%1")
  end

  local success, stdout, stderr = wezterm.run_child_process({"gsettings", "get", "org.gnome.desktop.interface", "cursor-size"})
  if success then
    xcursor_size = tonumber(stdout)
  end

  config.xcursor_theme = xcursor_theme
  config.xcursor_size = xcursor_size
end

config.window_frame = {
  font = wezterm.font({ family = "JetBrains Mono", weight = "Bold" }),
}

config.enable_tab_bar = false
-- config.colors = {
--   tab_bar = {
--     active_tab = {
--       bg_color = "#1c1c1c",
--       fg_color = "#ababab",
--     },
--   },
-- }

config.font = wezterm.font_with_fallback({
  {
    family = "JetBrainsMono Nerd Font Mono",
    weight = "Regular",
  },
  { family = "Terminus" },
})

-- wezterm.on("format-tab-title", function(tab)
--   local p = tab.active_pane
--   local idx = tab.is_active and "" or tab.tab_index + 1
--   local dir = basename(p.current_working_dir)

--   local title = idx .. " " .. dir

--   local proc = basename(p.foreground_process_name)
--   if proc ~= "zsh" then
--     title = title .. " " .. proc
--   end

--   return title
-- end)

return config

