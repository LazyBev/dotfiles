{ config, lib, pkgs, inputs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "gentuwu";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/London";
  
  # doas 
  security.doas = {
    enable = true;
    extraRules = [{
      users = [ "yari" ];
      keepEnv = true;
      persist = true;
    }];
  };
  
  # niri - pure Wayland compositor
  programs.niri.enable = true;

  # SDDM display manager with Wayland support
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  # PipeWire audio
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # XDG portal - gnome backend works with niri
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gnome ];
    config.niri.default = [ "gnome" "gtk" ];
  };

  # Required by Noctalia for wifi/bluetooth/power/battery widgets
  hardware.bluetooth.enable = true;
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;

  # Wayland env vars for Electron/Chromium apps
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
  };

  users.users.yari = {
    isNormalUser = true;
    extraGroups = [ "wheel" "audio" "video" "input" "networkmanager" ];
  };

  programs.firefox.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    xwayland-satellite        # X11 app compat layer
    networkmanagerapplet      # nm-applet for system tray
    brightnessctl             # required by Noctalia
    imagemagick               # required by Noctalia (template/wallpaper processing)
    python3                   # required by Noctalia
    cliphist                  # clipboard history (optional Noctalia feature)
    wl-clipboard              # wl-copy / wl-paste
    pulseaudio
    alsa-utils
  ];

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-color-emoji
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "26.05";
}
