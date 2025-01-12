{
  description = "A scrollable-tiling Wayland compositor.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";

    niri-stable.url = "github:YaLTeR/niri/v0.1.10.1";
    niri-unstable.url = "github:YaLTeR/niri";

    xwayland-satellite-stable.url = "github:Supreeeme/xwayland-satellite/v0.5";
    xwayland-satellite-unstable.url = "github:Supreeeme/xwayland-satellite";

    # they do all have flakes, but we specifically want just the Rust sources and no flakes.
    niri-stable.flake = false;
    niri-unstable.flake = false;
    xwayland-satellite-stable.flake = false;
    xwayland-satellite-unstable.flake = false;
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    nixpkgs-stable,
    ...
  }: let
    call = nixpkgs.lib.flip import {
      inherit inputs kdl docs binds settings;
      inherit (nixpkgs) lib;
    };
    kdl = call ./kdl.nix;
    binds = call ./parse-binds.nix;
    docs = call ./generate-docs.nix;
    settings = call ./settings.nix;
    stylix-module = call ./stylix.nix;

    stable-revs = import ./refs.nix;

    date = {
      year = builtins.substring 0 4;
      month = builtins.substring 4 2;
      day = builtins.substring 6 2;
      hour = builtins.substring 8 2;
      minute = builtins.substring 10 2;
      second = builtins.substring 12 2;
    };

    fmt-date = raw: "${date.year raw}-${date.month raw}-${date.day raw}";
    fmt-time = raw: "${date.hour raw}:${date.minute raw}:${date.second raw}";

    # note: against nixpkgs convention, i don't strip the "v"
    # this is in part just slightly easier, but also distinguishes these package versions from nixpkgs

    version-string = src:
      if stable-revs ? ${src.rev}
      then "stable ${stable-revs.${src.rev}} (commit ${src.rev})"
      else "unstable ${fmt-date src.lastModifiedDate} (commit ${src.rev})";

    package-version = src:
      if stable-revs ? ${src.rev}
      then stable-revs.${src.rev}
      else "unstable-${fmt-date src.lastModifiedDate}-${src.shortRev}";

    make-niri = {
      src,
      patches ? [],
      rustPlatform,
      pkg-config,
      wayland,
      systemdLibs,
      eudev,
      pipewire,
      mesa,
      libglvnd,
      seatd,
      libinput,
      libxkbcommon,
      libdisplay-info,
      pango,
      withDbus ? true,
      withDinit ? false,
      withScreencastSupport ? true,
      withSystemd ? true,
    }:
      rustPlatform.buildRustPackage {
        pname = "niri";
        version = package-version src;
        inherit src patches;
        cargoLock = {
          lockFile = "${src}/Cargo.lock";
          allowBuiltinFetchGit = true;
        };
        nativeBuildInputs = [
          pkg-config
          rustPlatform.bindgenHook
        ];

        buildInputs =
          [
            wayland
            mesa
            libglvnd
            seatd
            libinput
            libdisplay-info
            libxkbcommon
            pango
          ]
          ++ nixpkgs.lib.optional withScreencastSupport pipewire
          ++ nixpkgs.lib.optional withSystemd systemdLibs # we only need udev, really.
          ++ nixpkgs.lib.optional (!withSystemd) eudev; # drop-in replacement for systemd-udev

        buildNoDefaultFeatures = true;
        buildFeatures =
          nixpkgs.lib.optional withDbus "dbus"
          ++ nixpkgs.lib.optional withDinit "dinit"
          ++ nixpkgs.lib.optional withScreencastSupport "xdp-gnome-screencast"
          ++ nixpkgs.lib.optional withSystemd "systemd";

        passthru.providedSessions = ["niri"];

        # we want backtraces to be readable
        dontStrip = true;

        RUSTFLAGS = [
          "-C link-arg=-Wl,--push-state,--no-as-needed"
          "-C link-arg=-lEGL"
          "-C link-arg=-lwayland-client"
          "-C link-arg=-Wl,--pop-state"

          "-C debuginfo=line-tables-only"
        ];

        NIRI_BUILD_VERSION_STRING = version-string src;

        # previously, the second line was part of RUSTFLAGS above
        # but i noticed it stopped working? because it doesn't interpolate the env var anymore.
        #
        # i don't know when or why it stopped working. but moving it here fixes it.
        # the first line was unnecessary previously because this should be the default
        # https://github.com/NixOS/nixpkgs/blob/11cf80ae321c35132c1aff950f026e9783f06fec/pkgs/build-support/rust/build-rust-crate/build-crate.nix#L19
        # but for some reason it isn't. so i'm doing it manually.
        #
        # the purpose is to make backtraces more readable. the first line strips the useless `/build` prefix
        # and the second line makes niri-related paths more obvious as if they were based on pwd with `cargo run`
        postPatch = ''
          export RUSTFLAGS="$RUSTFLAGS --remap-path-prefix $NIX_BUILD_TOP=/"
          export RUSTFLAGS="$RUSTFLAGS --remap-path-prefix $NIX_BUILD_TOP/source=./"

          patchShebangs resources/niri-session
        '';

        # ever since this commit:
        # https://github.com/YaLTeR/niri/commit/771ea1e81557ffe7af9cbdbec161601575b64d81
        # niri now runs an actual instance of the real compositor (with a mock backend) during tests
        # and thus creates a real socket file in the runtime dir.
        # this is fine for our build, we just need to make sure it has a directory to write to.
        #
        # additionally, these tests are mutlithreaded, and can cause conflicts between threads
        # when writing to the same socket. so, to avoid failures, we limit it to just one thread.
        #
        # i believe both of these should be removed once niri doesn't create socket files during tests.
        # see https://github.com/YaLTeR/niri/issues/953
        preCheck = ''
          export XDG_RUNTIME_DIR="$(mktemp -d)"
          export RAYON_NUM_THREADS=1
        '';

        postInstall =
          # niri.desktop calls `niri-session` and that executable only works with systemd or dinit
          nixpkgs.lib.optionalString (withSystemd || withDinit) ''
            install -Dm0755 resources/niri-session -t $out/bin
            install -Dm0644 resources/niri.desktop -t $out/share/wayland-sessions
          ''
          # any of these features will enable dbus support
          + nixpkgs.lib.optionalString (withDbus || withScreencastSupport || withSystemd) ''
            install -Dm0644 resources/niri-portals.conf -t $out/share/xdg-desktop-portal
          ''
          + nixpkgs.lib.optionalString withSystemd ''
            install -Dm0644 resources/niri{-shutdown.target,.service} -t $out/lib/systemd/user
          ''
          + nixpkgs.lib.optionalString withDinit ''
            install -Dm0644 resources/dinit/niri{,-shutdown} -t $out/lib/dinit.d/user
          '';

        postFixup = ''
          substituteInPlace $out/lib/systemd/user/niri.service --replace-fail /usr/bin $out/bin
        '';

        meta = {
          description = "Scrollable-tiling Wayland compositor";
          homepage = "https://github.com/YaLTeR/niri";
          license = nixpkgs.lib.licenses.gpl3Only;
          maintainers = with nixpkgs.lib.maintainers; [sodiboo];
          mainProgram = "niri";
          platforms = nixpkgs.lib.platforms.linux;
        };
      };

    validated-config-for = pkgs: package: config:
      pkgs.runCommand "config.kdl" {
        inherit config;
        passAsFile = ["config"];
        buildInputs = [package];
      } ''
        niri validate -c $configPath
        cp $configPath $out
      '';

    make-xwayland-satellite = {
      src,
      patches ? [],
      rustPlatform,
      pkg-config,
      makeWrapper,
      xwayland,
      xcb-util-cursor,
      withSystemd ? true,
    }:
      rustPlatform.buildRustPackage {
        pname = "xwayland-satellite";
        version = package-version src;
        inherit src patches;
        cargoLock = {
          lockFile = "${src}/Cargo.lock";
          allowBuiltinFetchGit = true;
        };
        nativeBuildInputs = [
          pkg-config
          rustPlatform.bindgenHook
        ];

        buildInputs = [
          xcb-util-cursor
          makeWrapper
        ];

        buildNoDefaultFeatures = true;
        buildFeatures = nixpkgs.lib.optional withSystemd "systemd";

        # All tests require a display server to be running.
        doCheck = false;

        postInstall =
          ''
            wrapProgram $out/bin/xwayland-satellite \
              --prefix PATH : "${nixpkgs.lib.makeBinPath [xwayland]}"
          ''
          + nixpkgs.lib.optionalString withSystemd ''
            install -Dm0644 resources/xwayland-satellite.service -t $out/lib/systemd/user
          '';

        postFixup = nixpkgs.lib.optionalString withSystemd ''
          substituteInPlace $out/lib/systemd/user/xwayland-satellite.service \
            --replace-fail /usr/local/bin $out/bin
        '';

        meta = {
          description = "Rootless Xwayland integration to any Wayland compositor implementing xdg_wm_base";
          homepage = "https://github.com/Supreeeme/xwayland-satellite";
          license = nixpkgs.lib.licenses.mpl20;
          maintainers = with nixpkgs.lib.maintainers; [sodiboo];
          mainProgram = "xwayland-satellite";
          platforms = nixpkgs.lib.platforms.linux;
        };
      };

    make-package-set = pkgs: {
      niri-stable = pkgs.callPackage make-niri {
        src = inputs.niri-stable;
      };
      niri-unstable = pkgs.callPackage make-niri {
        src = inputs.niri-unstable;
      };
      xwayland-satellite-stable = pkgs.callPackage make-xwayland-satellite {
        src = inputs.xwayland-satellite-stable;
      };
      xwayland-satellite-unstable = pkgs.callPackage make-xwayland-satellite {
        src = inputs.xwayland-satellite-unstable;
      };
    };

    combined-closure = pkgs-name: pkgs:
      pkgs.runCommand "niri-flake-packages-for-${pkgs-name}" {} (''
          mkdir $out
        ''
        + builtins.concatStringsSep "" (nixpkgs.lib.mapAttrsToList (name: package: ''
            ln -s ${package} $out/${name}
          '')
          (make-package-set pkgs)));

    cached-packages-for = system:
      nixpkgs.legacyPackages.${system}.runCommand "all-niri-flake-packages" {} (''
          mkdir $out
        ''
        + builtins.concatStringsSep "" (nixpkgs.lib.mapAttrsToList (name: nixpkgs': ''
            ln -s ${combined-closure name nixpkgs'.legacyPackages.${system}} $out/${name}
          '') {
            nixos-unstable = nixpkgs;
            "nixos-24.11" = nixpkgs-stable;
          }));

    systems = ["x86_64-linux" "aarch64-linux"];

    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    lib = {
      inherit kdl;
      internal = {
        inherit make-package-set validated-config-for;
        package-set = abort "niri-flake internals: `package-set.\${package} pkgs` is now `(make-package-set pkgs).\${package}`";
        docs-markdown = docs.make-docs (settings.fake-docs {inherit fmt-date fmt-time;});
        settings-module = settings.module;
      };
    };

    packages = forAllSystems (system: make-package-set inputs.nixpkgs.legacyPackages.${system});

    overlays.niri = final: prev: (make-package-set final
      // {
        xwayland-satellite-nixpkgs = nixpkgs.lib.warn "please change pkgs.xwayland-satellite-nixpkgs -> pkgs.xwayland-satellite" prev.xwayland-satellite;
      });

    apps = forAllSystems (system:
      (
        builtins.mapAttrs (
          name: package: {
            type = "app";
            program = nixpkgs.lib.getExe package;
          }
        ) (make-package-set inputs.nixpkgs.legacyPackages.${system})
      )
      // {
        default = self.apps.${system}.niri-stable;
      });

    formatter = forAllSystems (system: inputs.nixpkgs.legacyPackages.${system}.alejandra);

    devShells = forAllSystems (system: let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        packages = with pkgs; [
          just
          fish
          fd
          entr
          moreutils
        ];

        shellHook = ''
          just hook 2>/dev/null
        '';
      };
    });

    homeModules.stylix = stylix-module;
    homeModules.config = {
      config,
      pkgs,
      ...
    }: let
      cfg = config.programs.niri;
    in {
      imports = [
        settings.module
      ];

      options.programs.niri = {
        package = nixpkgs.lib.mkOption {
          type = nixpkgs.lib.types.package;
          default = (make-package-set pkgs).niri-stable;
        };
      };

      config.lib.niri = {
        actions = nixpkgs.lib.mergeAttrsList (map ({
          name,
          fn,
          ...
        }: {
          ${name} = fn;
        }) (binds cfg.package.src));
      };

      config.xdg.configFile.niri-config = {
        enable = cfg.finalConfig != null;
        target = "niri/config.kdl";
        source = validated-config-for pkgs cfg.package cfg.finalConfig;
      };
    };
    nixosModules.niri = {
      config,
      options,
      pkgs,
      ...
    }: let
      cfg = config.programs.niri;
    in {
      # The module from this flake predates the module in nixpkgs by a long shot.
      # To avoid conflicts, we disable the nixpkgs module.
      # Eventually, this module (e.g. `niri.nixosModules.niri`) will be deprecated
      # in favour of other modules that aren't redundant with nixpkgs (and don't yet exist)
      disabledModules = ["programs/wayland/niri.nix"];

      options.programs.niri = {
        enable = nixpkgs.lib.mkEnableOption "niri";
        package = nixpkgs.lib.mkOption {
          type = nixpkgs.lib.types.package;
          default = (make-package-set pkgs).niri-stable;
        };
      };

      options.niri-flake.cache.enable = nixpkgs.lib.mkOption {
        type = nixpkgs.lib.types.bool;
        default = true;
      };

      config = nixpkgs.lib.mkMerge [
        (nixpkgs.lib.mkIf config.niri-flake.cache.enable {
          nix.settings = {
            substituters = ["https://niri.cachix.org"];
            trusted-public-keys = ["niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="];
          };
        })
        {
          environment.systemPackages = [pkgs.xdg-utils];
          xdg = {
            autostart.enable = nixpkgs.lib.mkDefault true;
            menus.enable = nixpkgs.lib.mkDefault true;
            mime.enable = nixpkgs.lib.mkDefault true;
            icons.enable = nixpkgs.lib.mkDefault true;
          };
        }
        (nixpkgs.lib.mkIf cfg.enable {
          services =
            if nixpkgs.lib.strings.versionAtLeast config.system.nixos.release "24.05"
            then {
              displayManager.sessionPackages = [cfg.package];
            }
            else {
              xserver.displayManager.sessionPackages = [cfg.package];
            };
          hardware =
            if nixpkgs.lib.strings.versionAtLeast config.system.nixos.release "24.11"
            then {
              graphics.enable = nixpkgs.lib.mkDefault true;
            }
            else {
              opengl.enable = nixpkgs.lib.mkDefault true;
            };
        })
        (nixpkgs.lib.mkIf cfg.enable {
          environment.systemPackages = [cfg.package];
          xdg.portal = {
            enable = true;
            extraPortals = nixpkgs.lib.mkIf (
              !cfg.package.cargoBuildNoDefaultFeatures || builtins.elem "xdp-gnome-screencast" cfg.package.cargoBuildFeatures
            ) [pkgs.xdg-desktop-portal-gnome];
            configPackages = [cfg.package];
          };

          security.polkit.enable = true;
          services.gnome.gnome-keyring.enable = true;
          systemd.user.services.niri-flake-polkit = {
            description = "PolicyKit Authentication Agent provided by niri-flake";
            wantedBy = ["niri.service"];
            after = ["graphical-session.target"];
            partOf = ["graphical-session.target"];
            serviceConfig = {
              Type = "simple";
              ExecStart = "${pkgs.libsForQt5.polkit-kde-agent}/libexec/polkit-kde-authentication-agent-1";
              Restart = "on-failure";
              RestartSec = 1;
              TimeoutStopSec = 10;
            };
          };

          security.pam.services.swaylock = {};
          programs.dconf.enable = nixpkgs.lib.mkDefault true;
          fonts.enableDefaultPackages = nixpkgs.lib.mkDefault true;
        })
        (nixpkgs.lib.optionalAttrs (options ? home-manager) {
          home-manager.sharedModules =
            [
              self.homeModules.config
              {programs.niri.package = nixpkgs.lib.mkForce cfg.package;}
            ]
            ++ nixpkgs.lib.optionals (options ? stylix) [self.homeModules.stylix];
        })
      ];
    };
    homeModules.niri = {
      config,
      pkgs,
      ...
    }: let
      cfg = config.programs.niri;
    in {
      imports = [
        self.homeModules.config
      ];
      options.programs.niri = {
        enable = nixpkgs.lib.mkEnableOption "niri";
      };

      config = nixpkgs.lib.mkIf cfg.enable {
        home.packages = [cfg.package];
        services.gnome-keyring.enable = true;
        xdg.portal = {
          enable = true;
          extraPortals = nixpkgs.lib.mkIf (
            !cfg.package.cargoBuildNoDefaultFeatures || builtins.elem "xdp-gnome-screencast" cfg.package.cargoBuildFeatures
          ) [pkgs.xdg-desktop-portal-gnome];
          configPackages = [cfg.package];
        };
      };
    };

    checks = forAllSystems (system: let
      test-nixos-for = nixpkgs: modules:
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules =
            [
              {
                # This doesn't need to be a bootable system. It just needs to build.
                system.stateVersion = "23.11";
                fileSystems."/".fsType = "ext4";
                fileSystems."/".device = "/dev/sda1";
                boot.loader.systemd-boot.enable = true;
              }
            ]
            ++ modules;
        })
        .config
        .system
        .build
        .toplevel;
    in {
      cached-packages = cached-packages-for system;
      empty-config-valid-stable = let
        eval = nixpkgs.lib.evalModules {
          modules = [
            settings.module
            {
              config.programs.niri.settings = {};
            }
          ];
        };
      in
        validated-config-for inputs.nixpkgs.legacyPackages.${system} self.packages.${system}.niri-stable eval.config.programs.niri.finalConfig;

      nixos-unstable = test-nixos-for nixpkgs [
        self.nixosModules.niri
        {
          programs.niri.enable = true;
        }
      ];

      nixos-stable = test-nixos-for nixpkgs-stable [
        self.nixosModules.niri
        {
          programs.niri.enable = true;
        }
      ];
    });
  };
}
