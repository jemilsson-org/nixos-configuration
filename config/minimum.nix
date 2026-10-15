{ config, lib, pkgs, ... }:
{

  programs = {
    zsh = {
      enable = true;
      # compinit, autosuggestions, syntax highlighting and the prompt theme
      # are all done from interactiveShellInit below (instead of the usual
      # module options) so they can be skipped in one place when Claude Code
      # drives the shell ($CLAUDECODE=1): none of them are needed for a
      # non-interactive-ish `zsh -i -c ...` run and they dominate interactive
      # startup time. Human shells are unaffected.
      enableGlobalCompInit = false;
      # Empty out the module's default promptInit ("prompt suse"): it runs
      # after interactiveShellInit and would otherwise stomp the powerlevel9k
      # PROMPT set below on every login.
      promptInit = "";
      interactiveShellInit = ''
        if [[ -z "$CLAUDECODE" ]]; then
          autoload -Uz compinit
          compinit
          source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
          source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
          source ${pkgs.zsh-powerlevel9k}/share/zsh-powerlevel9k/powerlevel9k.zsh-theme
        fi
      '';
    };
  };

  users.defaultUserShell = "/run/current-system/sw/bin/zsh";

  # Mergiraf: syntax-aware git merge driver, applied to all files via
  # /etc/gitattributes. It falls back to git's line merge for unsupported types.
  # diff3 conflict style is what mergiraf recommends; ~/.gitconfig overrides it.
  programs.git = {
    enable = true;
    attributes = "* merge=mergiraf";
    config = {
      merge = {
        conflictstyle = "diff3";
        mergiraf = {
          name = "mergiraf";
          driver = "${pkgs.mergiraf}/bin/mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L";
        };
      };
    };
  };

  environment = {
    systemPackages = with pkgs; [
      #System tools
      htop
      wget
      curl
      mergiraf

      file
      usbutils

      #Network tools
      tcpdump
      whois
      traceroute
    ];
  };

  networking = {
    #search = [ "jonas.systems" ];
  };

}
