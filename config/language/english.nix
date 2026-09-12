{ config, lib, pkgs, ... }:
let
  # en_DK is the glibc locale whose LC_TIME is ISO 8601 (2026-09-12T10:00:00).
  iso8601 = "en_DK.UTF-8";
  swedish = "sv_SE.UTF-8";
  english = "en_US.UTF-8";
in
{
  i18n = {
    defaultLocale = english;
    extraLocaleSettings = {
      LC_CTYPE = swedish;
      LC_NUMERIC = swedish;
      LC_TIME = iso8601;
      LC_COLLATE = swedish;
      LC_MONETARY = swedish;
      LC_MESSAGES = english;
      LC_PAPER = swedish;
      LC_NAME = swedish;
      LC_ADDRESS = swedish;
      LC_TELEPHONE = swedish;
      LC_MEASUREMENT = swedish;
      LC_IDENTIFICATION = swedish;
    };

  };
}
