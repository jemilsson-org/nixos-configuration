{ config, lib, pkgs, ... }:

let
  # Custom WhiteSur packages from nixpkgs-jemilsson
  whitesur-wallpapers = pkgs.jemilsson.whitesur-wallpapers;
  whitesur-firefox-theme = pkgs.jemilsson.whitesur-firefox-theme;
in
{
  # Unified appearance configuration for consistent theming across all applications
  # Including GTK, Qt, fonts, icons, and browser theming

  # Font packages
  fonts.packages = with pkgs; [
    vegur
    ibm-plex
    lmodern
    lmmath
    th-sarabun-new
    noto-fonts
    noto-fonts-color-emoji
    font-awesome
    # WhiteSur theme packages
    whitesur-gtk-theme
    whitesur-icon-theme
    whitesur-cursors
    nordzy-icon-theme
    # Additional theme packages
    gnome-themes-extra
    adwaita-icon-theme
    papirus-icon-theme
  ];

  # Font configuration
  fonts = {
    enableDefaultPackages = true;
    
    fontconfig = {
      enable = true;
      
      # Set IBM Plex as default fonts (Vegur reserved for headings)
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

  # Enhanced font configuration with priority enforcement and rejection rules
  environment.etc."xdg/fontconfig/conf.d/00-force-ibm-plex.conf".text = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <!-- Strong binding for IBM Plex Sans as primary sans-serif font -->
      <alias binding="strong">
        <family>sans-serif</family>
        <prefer><family>IBM Plex Sans</family></prefer>
      </alias>
      
      <alias binding="strong">
        <family>serif</family>
        <prefer><family>IBM Plex Serif</family></prefer>
      </alias>
      
      <alias binding="strong">
        <family>monospace</family>
        <prefer><family>IBM Plex Mono</family></prefer>
      </alias>
    </fontconfig>
  '';

  environment.etc."xdg/fontconfig/conf.d/01-reject-problematic-fonts.conf".text = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <!-- Reject fonts that commonly interfere with IBM Plex -->
      <selectfont>
        <rejectfont>
          <pattern><patelt name="family"><string>DejaVu Sans</string></patelt></pattern>
        </rejectfont>
        <rejectfont>
          <pattern><patelt name="family"><string>Ubuntu</string></patelt></pattern>
        </rejectfont>
        <rejectfont>
          <pattern><patelt name="family"><string>Liberation Sans</string></patelt></pattern>
        </rejectfont>
        <!-- wine-fonts system.ttf: family "System", empty charset. Web font
             stacks starting with "system" match it and render no glyphs. -->
        <rejectfont>
          <pattern><patelt name="family"><string>System</string></patelt></pattern>
        </rejectfont>
      </selectfont>
    </fontconfig>
  '';

  environment.etc."xdg/fontconfig/conf.d/02-vegur-headings.conf".text = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <!-- Vegur for headings and display text -->
      <alias binding="strong">
        <family>display</family>
        <prefer><family>Vegur</family></prefer>
      </alias>
      
      <alias binding="strong">
        <family>heading</family>
        <prefer><family>Vegur</family></prefer>
      </alias>
    </fontconfig>
  '';

  environment.etc."xdg/fontconfig/conf.d/10-ibm-plex-mapping.conf".text = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <!-- Comprehensive font mapping to IBM Plex -->
      <match target="pattern">
        <test qual="any" name="family"><string>Helvetica</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Sans</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Arial</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Sans</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Verdana</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Sans</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Tahoma</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Sans</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Times New Roman</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Serif</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Times</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Serif</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Georgia</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Serif</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Courier New</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Mono</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Courier</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Mono</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Monaco</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Mono</string></edit>
      </match>
      
      <match target="pattern">
        <test qual="any" name="family"><string>Consolas</string></test>
        <edit name="family" mode="assign" binding="strong"><string>IBM Plex Mono</string></edit>
      </match>
    </fontconfig>
  '';

  # GTK theming configuration
  programs.dconf.enable = true;

  # Accessibility: enable AT-SPI2 bus for window content access
  services.gnome.at-spi2-core.enable = true;

  # WhiteSur Dark theme with Nord color palette
  environment.etc."gtk-3.0/settings.ini" = {
    text = ''
      [Settings]
      gtk-theme-name=WhiteSur-Dark
      gtk-icon-theme-name=Nordzy
      gtk-font-name=IBM Plex Sans 10
      gtk-cursor-theme-name=WhiteSur-cursors
      gtk-cursor-theme-size=24
      gtk-toolbar-style=GTK_TOOLBAR_ICONS
      gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
      gtk-button-images=1
      gtk-menu-images=1
      gtk-enable-event-sounds=1
      gtk-enable-input-feedback-sounds=1
      gtk-xft-antialias=1
      gtk-xft-hinting=1
      gtk-xft-hintstyle=hintslight
      gtk-xft-rgba=rgb
      gtk-application-prefer-dark-theme=1
    '';
    mode = "444";
  };

  # GTK2 WhiteSur Dark theme configuration
  environment.etc."gtk-2.0/gtkrc" = {
    text = ''
      gtk-theme-name="WhiteSur-Dark"
      gtk-icon-theme-name="Nordzy"
      gtk-font-name="IBM Plex Sans 10"
      gtk-cursor-theme-name="WhiteSur-cursors"
      gtk-cursor-theme-size=24
      gtk-toolbar-style=GTK_TOOLBAR_ICONS
      gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
      gtk-button-images=1
      gtk-menu-images=1
      gtk-enable-event-sounds=1
      gtk-enable-input-feedback-sounds=1
      gtk-xft-antialias=1
      gtk-xft-hinting=1
      gtk-xft-hintstyle="hintslight"
      gtk-xft-rgba="rgb"
    '';
    mode = "444";
  };

  # Qt theming to match WhiteSur Dark
  qt = {
    enable = true;
    platformTheme = "gtk2";
    style = lib.mkForce "adwaita-dark";
  };

  # Environment variables for WhiteSur Dark with Nord colors
  environment.sessionVariables = {
    # WhiteSur Dark GTK theme
    GTK_THEME = "WhiteSur-Dark";
    
    # Qt settings to match WhiteSur Dark
    QT_QPA_PLATFORMTHEME = "gtk2";
    
    # CHROMIUM_FLAGS removed 2026-06: dead since the bwrap rewrap - the inner
    # nixpkgs chromium wrapper never reads $CHROMIUM_FLAGS, so none of the
    # flags set here were applied. The load-bearing ones now live where they
    # take effect: WebRtcPipeWireCamera (PipeWire camera portal for mic+camera,
    # see the bwrap comment in desktop_base.nix), --font-render-hinting=none
    # and --force-dark-mode are in chromiumBase.commandLineArgs in
    # desktop_base.nix; Wayland comes from NIXOS_OZONE_WL=1 there.
    
    # WhiteSur cursor theme
    XCURSOR_THEME = "WhiteSur-cursors";
    XCURSOR_SIZE = "24";
    
    # Java applications with WhiteSur theming
    _JAVA_OPTIONS = "-Dawt.useSystemAAFontSettings=on -Dswing.aatext=true -Dfile.encoding=UTF-8 -Dswt.gtk.theme=WhiteSur-Dark";
    JAVA_FONTS = "/etc/java-fonts.properties";
    
    # Electron apps Nord styling
    ELECTRON_EXTRA_LAUNCH_ARGS = "@/etc/electron-flags.conf";
    
    # Wine with IBM Plex fonts
    WINEDLLOVERRIDES = "winemenubuilder.exe=d";
  };

  # System packages for theming
  environment.systemPackages = with pkgs; [
    # Theme packages
    gnome-themes-extra
    adwaita-icon-theme
    papirus-icon-theme
    paper-icon-theme
    hicolor-icon-theme
    pantheon.elementary-icon-theme
    
    # WhiteSur theme packages
    whitesur-gtk-theme
    whitesur-icon-theme
    whitesur-cursors
    nordzy-icon-theme
    
    # Theme configuration tools
    lxappearance  # For manual GTK theme configuration
    libsForQt5.qt5ct  # For manual Qt5 configuration
    libsForQt5.qtstyleplugins  # Additional Qt style plugins
    
    # Cursor themes
    vanilla-dmz  # Additional cursor theme option
    
    # Custom WhiteSur theme assets
    whitesur-wallpapers
    whitesur-firefox-theme
  ];

  # XDG desktop portal for better theming integration
  xdg.portal = {
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
    ];
    # gtk handles most interfaces (file chooser, settings, etc.), but it does
    # NOT implement ScreenCast/Screenshot. Route those to the hyprland backend
    # explicitly so screen sharing doesn't rely on the deprecated UseIn fallback
    # (which xdg-desktop-portal warns about and will eventually drop).
    config = {
      common = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "hyprland" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "hyprland" ];
      };
    };
  };

  # Services for theme consistency
  services = {
    dbus.packages = with pkgs; [ gnome-themes-extra ];
    
    # GNOME keyring for theme consistency
    gnome.gnome-keyring.enable = true;
  };

  # Icon cache for better performance
  gtk.iconCache.enable = true;

  # Nord-themed browser user stylesheet with Aurora colors
  environment.etc."chromium/user-stylesheet.css".text = ''
    /* NixOS-inspired Dark Theme with NixOS Blue */
    :root {
      /* NixOS color palette */
      --nixos-dark-bg: #2e3440;
      --nixos-darker-bg: #242832;
      --nixos-light-bg: #3b4252;
      --nixos-blue: #5277c3; /* Primary NixOS blue */
      --nixos-light-blue: #7596d3; /* Lighter NixOS blue */
      --nixos-text: #d8dee9;
      --nixos-light-text: #eceff4;
      --nixos-accent: #5277c3;
      /* Status colors using NixOS blue variants */
      --nixos-success: #5e81ac; /* Muted blue-green */
      --nixos-warning: #d08770; /* Orange */
      --nixos-error: #bf616a; /* Red */
      --nixos-info: #5277c3; /* NixOS blue */
    }
    
    /* Global styling */
    * {
      font-family: "IBM Plex Sans", system-ui, sans-serif !important;
      line-height: 1.5 !important;
    }
    
    /* Headings and titles use Vegur */
    h1, h2, h3, h4, h5, h6,
    .title, .heading, [class*="title"], [class*="heading"],
    [role="heading"] {
      font-family: "Vegur", "IBM Plex Sans", sans-serif !important;
      font-weight: 600 !important;
    }
    
    /* Dark background */
    body, html {
      background-color: var(--nixos-dark-bg) !important;
      color: var(--nixos-text) !important;
    }
    
    /* Headings with NixOS color variants and Vegur font */
    h1 { 
      color: var(--nixos-blue) !important;
      font-family: "Vegur", sans-serif !important;
      font-size: 2em !important;
    }
    h2 { 
      color: var(--nixos-light-blue) !important;
      font-family: "Vegur", sans-serif !important;
      font-size: 1.5em !important;
    }
    h3 { 
      color: var(--nixos-accent) !important;
      font-family: "Vegur", sans-serif !important;
      font-size: 1.17em !important;
    }
    h4 { 
      color: var(--nixos-success) !important;
      font-family: "Vegur", sans-serif !important;
      font-size: 1em !important;
    }
    h5 { 
      color: var(--nixos-info) !important;
      font-family: "Vegur", sans-serif !important;
      font-size: 0.83em !important;
    }
    h6 { 
      color: var(--nixos-light-text) !important;
      font-family: "Vegur", sans-serif !important;
      font-size: 0.67em !important;
    }
    
    /* Links use NixOS blue colors */
    a {
      color: var(--nixos-blue) !important;
      text-decoration: none !important;
    }
    a:hover {
      color: var(--nixos-light-blue) !important;
      text-decoration: underline !important;
    }
    
    /* Forms with NixOS styling */
    input, textarea, select {
      background-color: var(--nixos-light-bg) !important;
      border: 1px solid var(--nixos-blue) !important;
      color: var(--nixos-text) !important;
      padding: 0.5em !important;
      border-radius: 4px !important;
    }
    
    /* Buttons with NixOS blue accent */
    button, input[type="button"], input[type="submit"] {
      background-color: var(--nixos-blue) !important;
      color: var(--nixos-light-text) !important;
      border: none !important;
      padding: 0.5em 1em !important;
      border-radius: 4px !important;
      cursor: pointer !important;
    }
    button:hover {
      background-color: var(--nixos-light-blue) !important;
    }
    
    /* Code blocks */
    code, pre {
      font-family: "IBM Plex Mono", monospace !important;
      background-color: var(--nixos-light-bg) !important;
      color: var(--nixos-success) !important;
      padding: 0.2em 0.4em !important;
      border-radius: 3px !important;
    }
  '';

  environment.etc."firefox/user.js".text = ''
    // Firefox font preferences for IBM Plex (with Vegur for fallback)
    user_pref("font.name.serif.x-western", "IBM Plex Serif");
    user_pref("font.name.sans-serif.x-western", "IBM Plex Sans");
    user_pref("font.name.monospace.x-western", "IBM Plex Mono");
    user_pref("font.name-list.serif.x-western", "IBM Plex Serif");
    user_pref("font.name-list.sans-serif.x-western", "IBM Plex Sans, Vegur");
    user_pref("font.name-list.monospace.x-western", "IBM Plex Mono");
    
    // Force font substitution
    user_pref("gfx.font_rendering.fontconfig.fontlist.enabled", true);
    user_pref("browser.display.use_document_fonts", 0);
  '';

  # Application-specific font configurations
  
  # VS Code font configuration
  environment.etc."Code/User/settings.json".text = builtins.toJSON {
    "editor.fontFamily" = "IBM Plex Mono, 'Courier New', monospace";
    "editor.fontSize" = 13;
    "editor.fontLigatures" = true;
    "terminal.integrated.fontFamily" = "IBM Plex Mono";
    "terminal.integrated.fontSize" = 13;
    "workbench.fontFamily" = "IBM Plex Sans";
    "chat.editor.fontFamily" = "IBM Plex Mono";
    "debug.console.fontFamily" = "IBM Plex Mono";
    "markdown.preview.fontFamily" = "IBM Plex Sans, sans-serif";
    "editor.codeLens.fontFamily" = "IBM Plex Sans";
    "markdown.styles" = [
      "h1, h2, h3, h4, h5, h6 { font-family: 'Vegur', 'IBM Plex Sans', sans-serif !important; }"
    ];
  };

  # Electron applications font configuration
  environment.etc."electron-flags.conf".text = ''
    --font-render-hinting=none
    --font-family="IBM Plex Sans"
    --enable-font-antialiasing
    --disable-font-subpixel-positioning
  '';

  # Java applications font configuration
  environment.etc."java-fonts.properties".text = ''
    # IBM Plex font mapping for Java applications
    serif.plain.latin-1=IBM Plex Serif
    serif.bold.latin-1=IBM Plex Serif Bold
    serif.italic.latin-1=IBM Plex Serif Italic
    serif.bolditalic.latin-1=IBM Plex Serif Bold Italic
    
    sansserif.plain.latin-1=IBM Plex Sans
    sansserif.bold.latin-1=IBM Plex Sans Bold
    sansserif.italic.latin-1=IBM Plex Sans Italic
    sansserif.bolditalic.latin-1=IBM Plex Sans Bold Italic
    
    monospaced.plain.latin-1=IBM Plex Mono
    monospaced.bold.latin-1=IBM Plex Mono Bold
    monospaced.italic.latin-1=IBM Plex Mono Italic
    monospaced.bolditalic.latin-1=IBM Plex Mono Bold Italic
  '';

  # Wine font configuration
  environment.etc."wine/fonts.reg".text = ''
    REGEDIT4

    [HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]
    "Arial"="IBM Plex Sans"
    "Helvetica"="IBM Plex Sans"
    "Times New Roman"="IBM Plex Serif"
    "Courier New"="IBM Plex Mono"
    "MS Sans Serif"="IBM Plex Sans"
    "MS Serif"="IBM Plex Serif"
    "System"="IBM Plex Sans"
  '';
}