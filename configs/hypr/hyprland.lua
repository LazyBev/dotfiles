-- Hyprland Lua config

return {
    monitor = {
        "eDP-1, 1920x1080@120.03, 0x0, 1",
    },

    general = {
        gaps_in = 10,
        gaps_out = 10,
        border_size = 2,
        ["col.active_border"] = "rgba(bd93f9ff)",
        ["col.inactive_border"] = "rgba(44475aff)",
        ["no_border_on_floating"] = false,
    },

    decoration = {
        rounding = 8,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        fullscreen_opacity = 1.0,
        blur = { enabled = false },
        shadow = { enabled = false },
    },

    input = {
        kb_layout = "gb",
        kb_options = "numpad:mac",
        touchpad = {
            natural_scroll = true,
            ["tap-to-click"] = true,
        },
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
    },

    master = {
        new_is_master = true,
        mfact = 1.0,
        orientation = "left",
        new_on_active = true,
        smart_resizing = true,
    },

    env = {
        "XDG_CURRENT_DESKTOP,Hyprland",
        "XDG_SESSION_TYPE,wayland",
        "XDG_SESSION_DESKTOP,Hyprland",
        "GDK_BACKEND,wayland",
        "GTK_USE_PORTAL,1",
        "QT_QPA_PLATFORM,wayland",
        "QT_WAYLAND_DISABLE_WINDOWDECORATION,1",
        "QT_AUTO_SCREEN_SCALE_FACTOR,1",
        "ELECTRON_OZONE_PLATFORM_HINT,wayland",
        "MOZ_ENABLE_WAYLAND,1",
        "SDL_VIDEODRIVER,wayland",
        "CLUTTER_BACKEND,wayland",
        "_JAVA_AWT_WM_NONREPARENTING,1",
        "XCURSOR_THEME,catppuccin-mocha-mauve-cursors",
        "XCURSOR_SIZE,24",
    },

    windowrulev2 = {
        "float, title:^Picture-in-Picture$",
        "float, class:^(pavucontrol)$",
        "float, class:^(nm-connection-editor)$",
        "float, class:^(mpv)$",
        "size 640 360, class:^(mpv)$",
    },

    exec_once = {
        "fcitx5 -d",
        "dunst",
        "bash -c 'sleep 1 && nm-applet --indicator'",
        "swaybg -i ~/Pictures/matikanefuku.png",
    },

    bind = {
        -- App launchers
        "ALT, Return, exec, alacritty",
        "ALT, SHIFT, Return, exec, alacritty -e zellij",
        "ALT, B, exec, qutebrowser",
        "ALT, SHIFT, B, exec, librewolf",
        "ALT, T, exec, alacritty -e yazi",
        "ALT, SHIFT, T, exec, thunar",
        "ALT, E, exec, alacritty -e nvim",
        "ALT, SHIFT, E, exec, vscodium",
        "ALT, S, exec, alacritty -e rmpc",
        "ALT, SHIFT, S, exec, steam",
        "ALT, V, exec, alacritty -e btop",
        "ALT, SHIFT, V, exec, vesktop",
        "ALT, D, exec, fuzzel",
        "ALT, Y, exec, waypaper",

        -- System actions
        "ALT, Escape, exec, noctalia-shell ipc call sessionMenu toggle",
        "MOD, SHIFT, L, exec, hyprlock",
        "ALT, CTRL, P, exec, doas reboot",
        "ALT, SHIFT, P, exec, doas poweroff",
        "ALT, SHIFT, Backspace, exit",

        -- Screenshots (via grimblast)
        "ALT, X, exec, grimblast save area ~/Pictures/Screenshots/Screenshot_$(date +%Y-%m-%d_%H-%M-%S).png",
        "ALT, SHIFT, X, exec, grimblast save output ~/Pictures/Screenshots/Screenshot_$(date +%Y-%m-%d_%H-%M-%S).png",
        "ALT, CTRL, X, exec, grimblast save active ~/Pictures/Screenshots/Screenshot_$(date +%Y-%m-%d_%H-%M-%S).png",

        -- Close window
        "CTRL, ALT, Q, killactive",

        -- Focus movement (hjkl)
        "ALT, H, movefocus, l",
        "ALT, L, movefocus, r",
        "ALT, K, movefocus, u",
        "ALT, J, movefocus, d",

        -- Move windows
        "ALT, SHIFT, H, movewindow, l",
        "ALT, SHIFT, L, movewindow, r",
        "ALT, SHIFT, K, movewindow, u",
        "ALT, SHIFT, J, movewindow, d",

        -- Float / tiling
        "ALT, Tab, togglefloating",
        "ALT, CTRL, Tab, focuswindow, floating",
        "ALT, SPACE, focuswindow, tiling",

        -- Fullscreen
        "ALT, F, fullscreen",

        -- Resize
        "ALT, MINUS, resizeactive, -30 0",
        "ALT, EQUAL, resizeactive, 30 0",
        "ALT, SHIFT, MINUS, resizeactive, 0 -30",
        "ALT, SHIFT, EQUAL, resizeactive, 0 30",

        -- Layout
        "ALT, W, togglesplit",

        -- Swap with master / move between master/stack
        "ALT, Comma, layoutmsg, swapwithmaster",
        "ALT, Period, layoutmsg, addtogroup",

        -- Workspace switching
        "ALT, 1, workspace, 1",
        "ALT, 2, workspace, 2",
        "ALT, 3, workspace, 3",
        "ALT, 4, workspace, 4",
        "ALT, 5, workspace, 5",
        "ALT, 6, workspace, 6",
        "ALT, 7, workspace, 7",
        "ALT, 8, workspace, 8",
        "ALT, 9, workspace, 9",
        "ALT, N, workspace, +1",
        "ALT, M, workspace, -1",

        -- Move to workspace
        "ALT, SHIFT, 1, movetoworkspace, 1",
        "ALT, SHIFT, 2, movetoworkspace, 2",
        "ALT, SHIFT, 3, movetoworkspace, 3",
        "ALT, SHIFT, 4, movetoworkspace, 4",
        "ALT, SHIFT, 5, movetoworkspace, 5",
        "ALT, SHIFT, 6, movetoworkspace, 6",
        "ALT, SHIFT, 7, movetoworkspace, 7",
        "ALT, SHIFT, 8, movetoworkspace, 8",
        "ALT, SHIFT, 9, movetoworkspace, 9",
        "ALT, SHIFT, N, movetoworkspace, +1",
        "ALT, SHIFT, M, movetoworkspace, -1",

        -- Media keys
        ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1+",
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1-",
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
        ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle",
        ", XF86AudioPlay, exec, playerctl play-pause",
        ", XF86AudioNext, exec, playerctl next",
        ", XF86AudioPrev, exec, playerctl previous",
        "ALT, CTRL, SPACE, exec, playerctl play-pause",
        "ALT, CTRL, L, exec, playerctl next",
        "ALT, CTRL, H, exec, playerctl previous",
    },
}
