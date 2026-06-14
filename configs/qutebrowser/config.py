config.load_autoconfig()

# =============================================================================
# Theme
# =============================================================================
Dracula = {
    "bg": "#282a36",
    "current": "#44475a",
    "fg": "#f8f8f2",
    "comment": "#6272a4",
    "cyan": "#8be9fd",
    "green": "#50fa7b",
    "orange": "#ffb86c",
    "pink": "#ff79c6",
    "purple": "#bd93f9",
    "red": "#ff5555",
    "yellow": "#f1fa8c",
}

# =============================================================================
# Colors
# =============================================================================
c.colors.tabs.selected.even.bg = Dracula["purple"]
c.colors.tabs.selected.even.fg = Dracula["bg"]
c.colors.tabs.selected.odd.bg = Dracula["purple"]
c.colors.tabs.selected.odd.fg = Dracula["bg"]
c.colors.tabs.indicator.start = Dracula["cyan"]
c.colors.tabs.indicator.stop = Dracula["purple"]
c.colors.tabs.indicator.error = Dracula["red"]
c.colors.statusbar.normal.bg = Dracula["bg"]
c.colors.statusbar.normal.fg = Dracula["fg"]
c.colors.statusbar.insert.bg = Dracula["current"]
c.colors.statusbar.insert.fg = Dracula["cyan"]
c.colors.statusbar.command.bg = Dracula["bg"]
c.colors.statusbar.command.fg = Dracula["fg"]
c.colors.statusbar.url.error.fg = Dracula["red"]
c.colors.statusbar.url.hover.fg = Dracula["purple"]
c.colors.statusbar.url.success.http.fg = Dracula["orange"]
c.colors.statusbar.url.success.https.fg = Dracula["green"]
c.colors.statusbar.url.warn.fg = Dracula["yellow"]
c.colors.prompts.bg = Dracula["bg"]
c.colors.prompts.fg = Dracula["fg"]
c.colors.prompts.selected.bg = Dracula["purple"]
c.colors.completion.category.bg = Dracula["bg"]
c.colors.completion.category.fg = Dracula["purple"]
c.colors.completion.even.bg = Dracula["bg"]
c.colors.completion.odd.bg = Dracula["bg"]
c.colors.completion.item.selected.bg = Dracula["current"]
c.colors.completion.item.selected.fg = Dracula["fg"]
c.colors.completion.item.selected.match.fg = Dracula["purple"]
c.colors.completion.fg = Dracula["fg"]
c.colors.completion.match.fg = Dracula["purple"]
c.colors.downloads.start.bg = Dracula["bg"]
c.colors.downloads.start.fg = Dracula["fg"]
c.colors.downloads.stop.bg = Dracula["purple"]
c.colors.downloads.stop.fg = Dracula["bg"]
c.colors.downloads.error.bg = Dracula["red"]
c.colors.downloads.error.fg = Dracula["fg"]
c.colors.hints.fg = Dracula["bg"]
c.colors.hints.bg = Dracula["purple"]
c.colors.hints.match.fg = Dracula["fg"]
c.colors.keyhint.fg = Dracula["fg"]
c.colors.keyhint.suffix.fg = Dracula["fg"]
c.colors.keyhint.bg = Dracula["bg"]
c.colors.messages.error.bg = Dracula["red"]
c.colors.messages.error.fg = Dracula["fg"]
c.colors.messages.warning.bg = Dracula["yellow"]
c.colors.messages.warning.fg = Dracula["bg"]
c.colors.messages.info.bg = Dracula["bg"]
c.colors.messages.info.fg = Dracula["fg"]
c.colors.webpage.preferred_color_scheme = "dark"

# =============================================================================
# Dark mode
# =============================================================================
c.colors.webpage.darkmode.enabled = True
c.colors.webpage.darkmode.policy.images = "never"

# =============================================================================
# Fonts
# =============================================================================
c.fonts.default_family = "Pragmasevka Nerd Font"
c.fonts.default_size = "11pt"
c.fonts.tabs.selected = "11pt Pragmasevka Nerd Font"
c.fonts.tabs.unselected = "11pt Pragmasevka Nerd Font"
c.fonts.statusbar = "11pt Pragmasevka Nerd Font"
c.fonts.prompts = "11pt Pragmasevka Nerd Font"
c.fonts.downloads = "11pt Pragmasevka Nerd Font"
c.fonts.keyhint = "11pt Pragmasevka Nerd Font"
c.fonts.completion.entry = "11pt Pragmasevka Nerd Font"
c.fonts.completion.category = "11pt Pragmasevka Nerd Font"

# =============================================================================
# URLs & Search
# =============================================================================
c.url.default_page = "http://localhost:8087"
c.url.start_pages = ["http://localhost:8087"]
c.url.auto_search = "naive"
c.url.searchengines = {
    "DEFAULT": "http://localhost:8087/search?q={}",
    "!a": "https://wiki.archlinux.org/?search={}",
    "!aw": "https://wiki.archlinux.org/?search={}",
    "!n": "https://wiki.nixos.org/?search={}",
    "!nix": "https://wiki.nixos.org/?search={}",
    "!np": "https://search.nixos.org/packages?query={}",
    "!no": "https://search.nixos.org/options?query={}",
    "!gh": "https://github.com/search?q={}",
    "!r": "https://reddit.com/r/{}",
    "!yt": "https://youtube.com/results?search_query={}",
    "!w": "https://en.wikipedia.org/wiki/{}",
    "!m": "https://www.google.com/maps?q={}",
    "!so": "https://stackoverflow.com/search?q={}",
}

# =============================================================================
# Tabs
# =============================================================================
c.tabs.position = "top"
c.tabs.show = "multiple"
c.tabs.indicator.width = 3
c.tabs.favicons.scale = 1.0
c.tabs.title.format = "{audio}{current_title}"
c.tabs.mousewheel_switching = False
c.tabs.new_position.related = "next"
c.tabs.new_position.unrelated = "last"

# =============================================================================
# Statusbar
# =============================================================================
c.statusbar.show = "in-mode"
c.statusbar.padding = {"top": 4, "bottom": 4, "left": 6, "right": 6}

# =============================================================================
# Downloads
# =============================================================================
c.downloads.position = "bottom"
c.downloads.remove_finished = 5000

# =============================================================================
# Scrolling
# =============================================================================
c.scrolling.smooth = True
c.scrolling.bar = "always"

# =============================================================================
# Completion
# =============================================================================
c.completion.height = "35%"
c.completion.show = "always"

# =============================================================================
# Content & Privacy
# =============================================================================
c.content.autoplay = False
c.content.notifications.enabled = False
c.content.geolocation = False
c.content.cookies.store = True
c.content.cookies.accept = "no-3rdparty"
c.content.blocking.enabled = True
c.content.blocking.method = "both"
c.content.blocking.adblock.lists = [
    "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt",
    "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances.txt",
    "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt",
    "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt",
]
c.content.headers.user_agent = "Mozilla/5.0 (X11; Linux x86_64; rv:136.0) Gecko/20100101 Firefox/136.0"
c.content.headers.accept_language = "en-US,en;q=0.9"

# =============================================================================
# Zoom
# =============================================================================
c.zoom.default = "100%"
c.zoom.mouse_divider = 512

# =============================================================================
# Editor
# =============================================================================
c.editor.command = ["alacritty", "-e", "nvim", "{file}", "-c", "normal {line}G{column}l"]

# =============================================================================
# Hints
# =============================================================================
c.hints.auto_follow = "unique-match"
c.hints.border = "1px solid #44475a"
c.hints.uppercase = True
c.hints.scatter = True

# =============================================================================
# Input
# =============================================================================
c.input.insert_mode.auto_load = False
c.input.insert_mode.auto_leave = True
c.input.partial_timeout = 5000

# =============================================================================
# Session
# =============================================================================
c.confirm_quit = ["downloads"]
c.auto_save.session = True
c.session.default_name = "default"

# =============================================================================
# Aliases
# =============================================================================
c.aliases = { "q": "close", "qa": "quit", "w": "session-save", "wq": "quit --save", "e": "open editor", "h": "back", "l": "forward" }

# =============================================================================
# Keybinds
# =============================================================================
config.bind("H", "back")
config.bind("L", "forward")
config.bind("J", "tab-prev")
config.bind("K", "tab-next")
config.bind("r", "reload")
config.bind("R", "reload --force")
config.bind("gg", "scroll-to-perc 0")
config.bind("G", "scroll-to-perc")
config.bind("j", "scroll down")
config.bind("k", "scroll up")
config.bind("h", "scroll left")
config.bind("l", "scroll right")
config.bind("t", "open -t")
config.bind("T", "cmd-set-text -s :open -t")
config.bind("o", "cmd-set-text -s :open")
config.bind("O", "cmd-set-text -s :open -t")
config.bind("d", "tab-close")
config.bind("u", "undo")
config.bind("f", "hint")
config.bind("F", "hint links tab")
config.bind("yy", "yank")
config.bind("yt", "yank title")
config.bind("+", "zoom-in")
config.bind("-", "zoom-out")
config.bind("=", "zoom")
config.bind("ZZ", "quit --save")
config.bind("ZQ", "quit")
