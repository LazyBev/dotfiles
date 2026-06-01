{ config, pkgs, inputs, ... }:

{
  home.username = "yari";
  home.homeDirectory = "/home/yari";
  home.stateVersion = "26.05";

  imports = [
    inputs.noctalia.homeModules.default
  ];

  # ── Packages ──────────────────────────────────────────────────────────────
  home.packages = with pkgs; [
    foot           # terminal
    fuzzel         # launcher
    grim           # screenshot
    slurp          # region select
    dunst          # notifications
    neovim         # editor
    dracula-theme  # GTK theme
    nemo           # file explorer
    swaybg         # wallpaper
    swaylock       # lock screen
    waypaper       # wallpaper switcher
    pavucontrol
  ];

  # ── Shell ─────────────────────────────────────────────────────────────────
  programs.bash = {
    enable = true;
    shellAliases = {
      miau = "miau, im a cat";
      rb   = "doas nixos-rebuild switch --flake /etc/nixos#gentuwu";
      edh  = "doas nvim /etc/nixos/home.nix";
      edc  = "doas nvim /etc/nixos/configuration.nix";
      edf  = "doas nvim /etc/nixos/flake.nix";
    };
  };

programs.git.enable = true;

  # ── GTK theme (Dracula) ───────────────────────────────────────────────────
  gtk = {
    enable = true;
    theme = {
      name = "Dracula";
      package = pkgs.dracula-theme;
    };
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
  };

  programs.noctalia-shell = {
    enable = true;
    settings  = ./dotfiles/configs/noctalia/settings.json;
    colors    = ./dotfiles/configs/noctalia/colors.json;
    plugins   = ./dotfiles/configs/noctalia/plugins.json;
    user-templates = ./dotfiles/configs/noctalia/user-templates.toml;
  };

  # ── Dotfile configs ───────────────────────────────────────────────────────
  xdg.configFile = {
    "niri/config.kdl".source = ./dotfiles/configs/niri/config.kdl;
    "foot".source            = ./dotfiles/configs/foot;
    "fuzzel".source          = ./dotfiles/configs/fuzzel;
    "dunst".source           = ./dotfiles/configs/dunst;
    "qutebrowser".source     = ./dotfiles/configs/qutebrowser;
    "fcitx5".source          = ./dotfiles/configs/fcitx5;
  };

  home.file."Pictures" = {
    source = ./dotfiles/Pictures;
    recursive = true;
  };
}
