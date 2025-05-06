{
  description = "Oscar Muhr's nix flake templates";

  inputs = { nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable"; };

  outputs = { nixpkgs, ... }:
    let inherit (nixpkgs) lib;
    in {
      templates = let
        root = ./templates;
        dirs = lib.attrNames (lib.filterAttrs (_: type: type == "directory")
          (builtins.readDir root));
      in lib.listToAttrs (map (dir:
        let
          path = root + "/${dir}";
          template = import (path + "/flake.nix");
        in lib.nameValuePair dir {
          inherit path;
          inherit (template) description;
        }) dirs);
    };
}
