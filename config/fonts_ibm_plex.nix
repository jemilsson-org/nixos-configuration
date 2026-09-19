{ config, lib, pkgs, ... }:

{
  # Font packages
  fonts.packages = with pkgs; [
    ibm-plex
    noto-fonts
    noto-fonts-color-emoji
    font-awesome
  ];

  # Font configuration
  fonts = {
    enableDefaultPackages = true;
    
    fontconfig = {
      enable = true;
      
      # Set IBM Plex as default fonts
      defaultFonts = {
        serif = [ "IBM Plex Serif" "Noto Serif" ];
        sansSerif = [ "IBM Plex Sans" "Noto Sans" ];
        monospace = [ "IBM Plex Mono" "JetBrains Mono" ];
        emoji = [ "Noto Color Emoji" ];
      };

      # Font rendering settings for better consistency
      antialias = true;
      hinting = {
        enable = true;
        style = "slight";
      };
      
      subpixel = {
        rgba = "rgb";
        lcdfilter = "default";
      };
    };
  };

  # GTK theming for consistency
  programs.dconf.enable = true;
  
  # Set GTK theme settings
  environment.sessionVariables = {
    # Font settings for GTK applications
    GTK_THEME = "Adwaita:dark";
  };

  # Qt theming to match GTK
  qt = {
    enable = true;
    platformTheme = "gtk2";
    style = "adwaita-dark";
  };

  # Configure default fonts for various applications
  fonts.fontconfig.confPackages = [ (pkgs.writeTextDir "etc/fonts/conf.d/10-ibm-plex.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <!-- Map common font requests to IBM Plex -->
      <match target="pattern">
        <test qual="any" name="family">
          <string>Helvetica</string>
        </test>
        <edit name="family" mode="assign" binding="same">
          <string>IBM Plex Sans</string>
        </edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family">
          <string>Arial</string>
        </test>
        <edit name="family" mode="assign" binding="same">
          <string>IBM Plex Sans</string>
        </edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family">
          <string>Times New Roman</string>
        </test>
        <edit name="family" mode="assign" binding="same">
          <string>IBM Plex Serif</string>
        </edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family">
          <string>Courier New</string>
        </test>
        <edit name="family" mode="assign" binding="same">
          <string>IBM Plex Mono</string>
        </edit>
      </match>
    </fontconfig>
  '') ];

  # Terminal font configuration is handled by user dotfiles
  # Alacritty and Foot configurations are in ~/.config/

  # Environment packages for theming
  environment.systemPackages = with pkgs; [
    gnome-themes-extra
    adwaita-icon-theme
    papirus-icon-theme
    lxappearance  # For manual GTK theme configuration if needed
    libsForQt5.qt5ct  # For manual Qt5 configuration if needed
  ];
}