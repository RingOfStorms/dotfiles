{ config, lib, pkgs, settings, ... } @ args:
{
  users.users.root = {
    initialPassword = "password1";
  };
}

