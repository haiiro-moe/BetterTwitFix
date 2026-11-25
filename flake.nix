{
  description = "BetterTwitFix (vxTwitter fork): Flask Twitter/X embed fixer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Both systems are supported; flake-utils is deliberately not used so the
      # flake has a single input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Python 3.12 matches `runtime: python3.12` in serverless.yml. The
      # Dockerfile uses 3.10, which nixpkgs no longer ships; 3.12 is the
      # closest supported interpreter. Do not move to the default `python3`
      # (3.14 in this channel) without re-testing the old pure-python deps.
      pythonFor = pkgs: pkgs.python312;

      # The three pins from requirements.txt that nixpkgs does not ship are
      # built from PyPI sdists with fixed hashes. Bump a pin by changing
      # `version` and `hash` (get the hash with
      # `nix hash convert --hash-algo sha256 --to sri <sha256 from pypi.org/pypi/<name>/<ver>/json>`).
      pyOverlay = pkgs: final: _prev: {
        numerize = final.buildPythonPackage rec {
          pname = "numerize";
          version = "0.12";
          pyproject = true;
          build-system = [ final.setuptools ];
          src = final.fetchPypi {
            inherit pname version;
            hash = "sha256-VUj+cq3OsseWSZgXlpfYARe7EX9XzQL4cs9dtA1hXAQ=";
          };
          doCheck = false; # no tests in the sdist
          pythonImportsCheck = [ "numerize" ];
          meta.license = pkgs.lib.licenses.mit;
        };

        # The PyPI project is PyRTF3, the import package is `PyRTF`. Built
        # from the wheel because the sdist needs setuptools-markdown and
        # setuptools_scm, which are not in nixpkgs.
        pyrtf3 = final.buildPythonPackage rec {
          pname = "PyRTF3";
          version = "0.47.5";
          format = "wheel";
          dependencies = [ final.pyparsing ];
          src = final.fetchPypi {
            inherit pname version format;
            dist = "py3";
            python = "py3";
            hash = "sha256-/HbX8MepvyQ2TYmyvrR5ieTcOWtyIyYxlph5Ddq3CcE=";
          };
          doCheck = false;
          pythonImportsCheck = [ "PyRTF" ];
          meta.license = pkgs.lib.licenses.gpl3Plus;
        };

        # Import package is `x_client_transaction`. Built from the
        # py3-none-any wheel: the sdist's setup.py reads a requirements.txt
        # that is not shipped in the tarball, so it cannot be built.
        xclienttransaction = final.buildPythonPackage rec {
          pname = "xclienttransaction";
          version = "1.0.2";
          format = "wheel";
          dependencies = [ final.beautifulsoup4 ];
          src = final.fetchPypi {
            inherit pname version format;
            dist = "py3";
            python = "py3";
            hash = "sha256-ZiUVVPAkcs0Ps6M7xkaM/rdAlJdU3cB9vkFk5DmshhM=";
          };
          doCheck = false;
          pythonImportsCheck = [ "x_client_transaction" ];
          meta.license = pkgs.lib.licenses.mit;
        };
      };

      pythonWithOverlay =
        pkgs:
        (pythonFor pkgs).override {
          self = pythonWithOverlay pkgs;
          packageOverrides = pyOverlay pkgs;
        };

      # Runtime dependencies = requirements.txt. Versions come from the
      # pinned nixpkgs, NOT from the pins in requirements.txt (see readme).
      # beautifulsoup4 is imported directly by twExtract/twUtils.py but is
      # only listed in requirements.txt transitively (via XClientTransaction).
      runtimeDeps = ps: [
        ps.flask
        ps.flask-cors
        ps.pymongo
        ps.boto3
        ps.requests
        ps.pillow
        ps.werkzeug
        ps.numerize
        ps.oauthlib
        ps.pyrtf3
        ps.xclienttransaction
        ps.deepl
        ps.beautifulsoup4
      ];

      # Test-only deps (`./run_tests.sh` needs pytest, pytest-cov, pytest-env).
      testDeps = ps: [
        ps.pytest
        ps.pytest-cov
        ps.pytest-env
      ];

      # uwsgi with the python plugin built against the same interpreter, used
      # by `uwsgi --ini twitfix.ini` in production.
      uwsgiFor =
        pkgs:
        pkgs.uwsgi.override {
          plugins = [ "python3" ];
          python3 = pythonWithOverlay pkgs;
        };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          python = pythonWithOverlay pkgs;
          pythonEnv = python.withPackages runtimeDeps;
          uwsgi = uwsgiFor pkgs;
        in
        rec {
          # The sources, laid out under share/twitfix, plus a `twitfix`
          # launcher. The store path is read-only, so the launcher runs from
          # the *caller's* working directory: config.json (auto-created on
          # first run) and links.json are read and written there, exactly as
          # with `python wsgi.py` in a checkout. The code and its templates
          # and static files are found via --pythonpath / Flask's root_path.
          twitfix = pkgs.stdenvNoCC.mkDerivation {
            pname = "twitfix";
            version = "0-unstable";
            src = pkgs.lib.cleanSourceWith {
              src = ./.;
              filter =
                path: type:
                let
                  base = baseNameOf path;
                in
                pkgs.lib.cleanSourceFilter path type
                && !(builtins.elem base [
                  "flake.nix"
                  "flake.lock"
                  "node_modules"
                  ".github"
                  "result"
                  ".direnv"
                  "venv"
                  "__pycache__"
                  "links.json"
                  "run_tests.sh"
                ])
                # Test modules stay out of the package, so a `result` symlink in
                # the checkout cannot make pytest collect duplicate modules.
                && !(pkgs.lib.hasPrefix "test_" base);
            };
            dontBuild = true;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            installPhase = ''
              runHook preInstall
              mkdir -p $out/share/twitfix $out/bin
              cp -r . $out/share/twitfix
              makeWrapper ${uwsgi}/bin/uwsgi $out/bin/twitfix \
                --prefix PATH : ${pythonEnv}/bin \
                --set PYTHONHOME ${pythonEnv} \
                --add-flags "--plugins-dir ${uwsgi}/lib/uwsgi --plugin python3" \
                --add-flags "--pythonpath $out/share/twitfix --module wsgi:app" \
                --add-flags "--http 0.0.0.0:5000 --master --processes 2 --die-on-term"
              runHook postInstall
            '';
            # Import check (without network): config is read from env here.
            doInstallCheck = true;
            installCheckPhase = ''
              cd $(mktemp -d)
              RUNNING_SERVERLESS=1 VXTWITTER_WORKAROUND_TOKENS=dummy \
                ${pythonEnv}/bin/python -I -c \
                "import sys; sys.path.insert(0, '$out/share/twitfix'); import twitfix; print(twitfix.app.name)"
            '';
            meta = {
              description = "Twitter/X embed fixer (vxTwitter fork), uwsgi launcher";
              license = pkgs.lib.licenses.wtfpl;
              mainProgram = "twitfix";
            };
          };
          default = twitfix;
        }
      );

      apps = forAllSystems (pkgs: {
        # `nix run .` : uwsgi HTTP server on :5000, state in the current dir.
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.twitfix}/bin/twitfix";
          meta.description = "Run BetterTwitFix under uwsgi on http://0.0.0.0:5000";
        };
        # `nix run .#dev` : the Flask dev server from a checkout, i.e.
        # `python wsgi.py`. Must be run from the repo root.
        dev = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "twitfix-dev" ''
              exec ${(pythonWithOverlay pkgs).withPackages runtimeDeps}/bin/python wsgi.py "$@"
            ''
          );
          meta.description = "Run `python wsgi.py` (Flask dev server, port 5000) from a checkout";
        };
      });

      devShells = forAllSystems (
        pkgs:
        let
          python = pythonWithOverlay pkgs;
          pythonEnv = python.withPackages (ps: runtimeDeps ps ++ testDeps ps);
        in
        {
          default = pkgs.mkShell {
            packages = [
              pythonEnv
              (uwsgiFor pkgs)
            ];
            shellHook = ''
              # twitfix.py reads config.json from the cwd, so run from the repo root.
              # The test suite needs a token set or `import twitfix` fails with an
              # AttributeError; "dummy" is enough for import/offline tests, real
              # requests need a real value. Override by exporting it first.
              export VXTWITTER_WORKAROUND_TOKENS="''${VXTWITTER_WORKAROUND_TOKENS:-dummy}"
              export PYTHONDONTWRITEBYTECODE=1
            '';
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
