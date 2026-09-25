{ config, lib, pkgs, ... }:
let

in
{
  #sound.mediaKeys.enable = true;


  services = {

    actkbd = {
      enable = true;
    };

    greetd = {
      enable = true;
      restart = true;
    };

    hypridle.enable = true;

    libinput = {
      enable = true;
    };

    system-config-printer.enable = true;

    xserver = {
      enable = true;
      xkb = {
        options = "eurosign:e";
        layout = "se";
      };

      windowManager = {
        hypr = {
          enable = true;
        };
      };

      displayManager = {
          sessionCommands = ''
          systemctl --user import-environment XDG_DATA_DIRS DBUS_SESSION_BUS_ADDRESS NO_AT_BRIDGE
        '';
        };

        
      };

    blueman.enable = true;

  };

  programs = {
    regreet = {
      enable = true;
      #settings = ./regreet.toml;
    };
    xwayland.enable = true;

    hyprland = {
      enable = true;
      xwayland = {
        enable = true;
      };
      package = pkgs.unstable.hyprland;
    };

    nm-applet = {
      enable = true;
      indicator = true;
    };


    hyprlock.enable = true;
    waybar.enable = true;

    system-config-printer.enable = true;

    
  };

  systemd = {
    user = {

      services = {

        kanshi = {
          enable = true;
          description = "kanshi";

          partOf = [ "graphical-session.target" ];
          requires = [ "graphical-session.target" ];
          after = [ "graphical-session.target" ];
          wantedBy = [ "graphical-session.target" ];

          environment = {
            XDG_CURRENT_DESKTOP = "sway";
            XDG_SESSION_TYPE = "wayland";
            WAYLAND_DISPLAY = "wayland-1";
            WLR_DRM_NO_MODIFIERS = "1";
          };
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.unstable.kanshi}/bin/kanshi";
            Restart = "always";
          };

        };

        shikane = {
          # Disabled: shikane raced kanshi (both are wlr-output-management
          # daemons) and fought over monitor positions. kanshi is the single
          # source of truth for output layout now.
          enable = false;
          description = "shikane";

          partOf = [ "graphical-session.target" ];
          requires = [ "graphical-session.target" ];
          after = [ "graphical-session.target" ];
          wantedBy = [ "graphical-session.target" ];

          environment = {
            XDG_CURRENT_DESKTOP = "sway";
            XDG_SESSION_TYPE = "wayland";
            WAYLAND_DISPLAY = "wayland-1";
            WLR_DRM_NO_MODIFIERS = "1";
          };
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.unstable.shikane}/bin/shikane";
            Restart = "always";
          };

        };
        
        "waybar" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            Restart = "always";
            RestartSec = 1;
          };
        };

        "pasystray" = {
          enable = true;
          description = "Pulse audio systray";
          wantedBy = [ "graphical-session.target" ];
          partOf = [ "graphical-session.target" ];
          serviceConfig.ExecStart = "${pkgs.pasystray}/bin/pasystray";
        };
      };
    };
  };


  environment.systemPackages = with pkgs; [
    xev

    pkgs.networkmanagerapplet

    unstable.hyprland
    unstable.hyprlock
    brightnessctl

    mako

    xdg-desktop-portal
    xdg-desktop-portal-wlr

    unstable.shikane
  ];


  nixpkgs.overlays = [
    (self: super: {
      waybar = super.waybar.overrideAttrs (oldAttrs: {
        mesonFlags = oldAttrs.mesonFlags ++ [ "-Dexperimental=true" ];
      });
    })
  ];


  environment.sessionVariables = {
  #  NIXOS_OZONE_WL = "1";
  #  MOZ_ENABLE_WAYLAND = "1";
  #  XDG_CURRENT_DESKTOP = "sway";
  #  XDG_SESSION_TYPE = "wayland";
  };
  console.useXkbConfig = true;
}
