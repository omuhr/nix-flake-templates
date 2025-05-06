{
  description = "python script";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix_hammer_overrides = {
      url = "github:TyberiusPrime/uv2nix_hammer_overrides";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, uv2nix, pyproject-nix, pyproject-build-systems
    , uv2nix_hammer_overrides, ... }:
    let
      inherit (nixpkgs) lib;

      name = "script";

      # Load a uv workspace from a workspace root.
      # Uv2nix treats all uv projects as workspace projects.
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      # Create package overlay from workspace.
      overlay = workspace.mkPyprojectOverlay {
        # Prefer prebuilt binary wheels as a package source.
        sourcePreference = "wheel";
      };

      # Extend generated overlay with build fixups
      #
      # Uv2nix can only work with what it has, and uv.lock is missing essential metadata to perform some builds.
      # This is an additional overlay implementing build fixups.
      # See:
      # - https://pyproject-nix.github.io/uv2nix/FAQ.html
      pyprojectOverrides =
        # Use overrides derived using https://github.com/TyberiusPrime/uv2nix_hammer
        pkgs.lib.composeExtensions (uv2nix_hammer_overrides.overrides pkgs) (
          # use uv2nix_hammer_overrides.overrides_debug
          # to see which versions were matched to which overrides
          # use uv2nix_hammer_overrides.overrides_strict / overrides_strict_debug
          # to use only overrides exactly matching your python package versions

          _final: _prev: {
            # place additional overlays here.
            #a_pkg = prev.a_pkg.overrideAttrs (old: nativeBuildInputs = old.nativeBuildInputs ++ [pkgs.someBuildTool] ++ (final.resolveBuildSystems { setuptools = [];});

            pyqt6-qt6 = _prev.pyqt6-qt6.overrideAttrs (old: {
              autoPatchelfIgnoreMissingDeps =
                [ "libmysqlclient.so.21" "libmimerapi.so" "libQt6*" ];
              propagatedBuildInputs = old.propagatedBuildInputs or [ ] ++ [
                pkgs.qt6.full # Isn't this kind of cheating? The whole point of pyqt6-qt6
                # is to provide only what pyqt6 needs, not the whole qt6.full.
                pkgs.libxkbcommon
                pkgs.gtk3
                pkgs.speechd
                pkgs.gst
                pkgs.gst_all_1.gst-plugins-base
                pkgs.gst_all_1.gstreamer
                pkgs.postgresql.lib
                pkgs.unixODBC
                pkgs.pcsclite
                pkgs.xorg.libxcb
                pkgs.xorg.xcbutil
                pkgs.xorg.xcbutilcursor
                pkgs.xorg.xcbutilerrors
                pkgs.xorg.xcbutilimage
                pkgs.xorg.xcbutilkeysyms
                pkgs.xorg.xcbutilrenderutil
                pkgs.xorg.xcbutilwm
                pkgs.libdrm
                pkgs.pulseaudio
              ];
            });

            # https://pypi.org/project/PyQt6/
            pyqt6 = _prev.pyqt6.overrideAttrs (old: {
              buildInputs = old.buildInputs or [ ] ++ [ _final.pyqt6-qt6 ];
            });
          });

      # This example is only using x86_64-linux
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      # Use Python 3.12 from nixpkgs
      python = pkgs.python312;

      # Construct package set
      pythonSet =
        # Use base package set from pyproject.nix builders
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope (lib.composeManyExtensions [
          pyproject-build-systems.overlays.default
          overlay
          pyprojectOverrides
        ]);

    in {
      # Package a virtual environment as our main application.
      #
      # Enable no optional dependencies for production build.
      packages.x86_64-linux.default =
        pythonSet.mkVirtualEnv "${name}-env" workspace.deps.default;

      # Make ${name} runnable with `nix run`
      apps.x86_64-linux = {
        default = {
          type = "app";
          program = "${self.packages.x86_64-linux.default}/bin/${name}";
        };
      };

      # Pure development using uv2nix to manage virtual environments
      devShells.x86_64-linux = {
        default = let
          # Create an overlay enabling editable mode for all local dependencies.
          # Note: Editable package support is still unstable and subject to change.
          editableOverlay = workspace.mkEditablePyprojectOverlay {
            # Use environment variable
            root = "$REPO_ROOT";
            # Optional: Only enable editable for these packages
            # members = [ "hello-world" ];
          };

          # Override previous set with our overrideable overlay.
          editablePythonSet = pythonSet.overrideScope
            (lib.composeManyExtensions [
              editableOverlay

              # Apply fixups for building an editable package of your workspace packages
              (final: prev: {
                script = prev.script.overrideAttrs (old: {
                  # It's a good idea to filter the sources going into an editable build
                  # so the editable package doesn't have to be rebuilt on every change.
                  src = lib.fileset.toSource {
                    root = old.src;
                    fileset = lib.fileset.unions [
                      (old.src + "/pyproject.toml")
                      (old.src + "/README.md")
                      (old.src + "/src/${name}/__init__.py")
                      (old.src + "/src/${name}/__main__.py")
                    ];
                  };

                  # Hatchling (our build system) has a dependency on the `editables` package when building editables.
                  #
                  # In normal Python flows this dependency is dynamically handled, and doesn't need to be explicitly declared.
                  # This behaviour is documented in PEP-660.
                  #
                  # With Nix the dependency needs to be explicitly declared.
                  nativeBuildInputs = old.nativeBuildInputs
                    ++ final.resolveBuildSystem { editables = [ ]; };
                });

              })
            ]);

          # Build virtual environment, with local packages being editable.
          #
          # Enable all optional dependencies for development.
          virtualenv =
            editablePythonSet.mkVirtualEnv "${name}-dev-env" workspace.deps.all;

        in pkgs.mkShell {
          packages = [ virtualenv pkgs.uv ];

          env = {
            # Don't create venv using uv
            UV_NO_SYNC = "1";

            # Force uv to use Python interpreter from venv
            UV_PYTHON = "${virtualenv}/bin/python";

            # Prevent uv from downloading managed Python's
            UV_PYTHON_DOWNLOADS = "never";
          };

          shellHook = ''
            # Undo dependency propagation by nixpkgs.
            unset PYTHONPATH

            # Initialize of git repository if this hasn't been done and track the files in the directory
            # This will happen on first init from template
            if ! [ -d .git ]; then
              ${pkgs.git}/bin/git init
              ${pkgs.git}/bin/git add -A
            fi;

            # Get repository root using git. This is expanded at runtime by the editable `.pth` machinery.
            export REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
          '';
        };
      };
    };
}
