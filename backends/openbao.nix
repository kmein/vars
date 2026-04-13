# OpenBao (open-source Vault fork) backend for vars.
# Secrets are generated locally then stored in an OpenBao KV v2 mount.
# At boot, a systemd service fetches them into a tmpfs directory so that
# the rest of the system can read them as ordinary files.
#
# Usage:
#   1. Enable the backend and point it at your OpenBao instance.
#   2. Run `generate-vars` once (as root, or with VAULT_TOKEN set) to
#      generate secrets and push them into OpenBao.
#   3. On subsequent boots the `fetch-vars` service pulls them back down.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.vars.settings.openbao;
  sortedGenerators =
    (lib.toposort (a: b: builtins.elem a.name b.dependencies) (lib.attrValues config.vars.generators))
    .result;

  flushStdin = ''
    if [ -t 0 ]; then while IFS= read -r -t 0.1 _discard; do :; done; fi
  '';
  promptCmd = {
    hidden = "read -sr prompt_value; ${flushStdin}";
    line = "read -r prompt_value; ${flushStdin}";
    multiline = ''
      echo 'press control-d to finish'
      prompt_value=$(cat)
    '';
  };

  # KV path for a file within the configured mount
  kvPath =
    gen: file:
    "${cfg.prefix}/${if file.secret then "secret" else "public"}/${gen.name}/${file.name}";

  # Shell snippet that sets VAULT_ADDR and VAULT_TOKEN
  authEnv = ''
    export VAULT_ADDR="''${VAULT_ADDR:-${cfg.address}}"
    export VAULT_TOKEN
    VAULT_TOKEN=$(< ${lib.escapeShellArg cfg.tokenFile})
  '';

  # Run by hand after provisioning to (re-)generate secrets and upload them.
  generate-vars = pkgs.writeShellApplication {
    name = "generate-vars";
    runtimeInputs = [
      pkgs.openbao
      pkgs.coreutils
    ];
    text = ''
      set -efuo pipefail

      # Set default permissions to only allow the owner to read/write
      umask 077

      ${authEnv}

      ${lib.concatMapStringsSep "\n" (
        gen:
        let
          templates = lib.filter (file: file.template != null) (lib.attrValues gen.files);
        in
        ''
          all_files_missing=true
          all_files_present=true
          found_files=""
          missing_files=""
          echo "Checking vars for ${gen.name}..."
          ${lib.concatMapStringsSep "\n" (file: ''
            if bao kv get \
                -mount=${lib.escapeShellArg cfg.mount} \
                -field=content \
                ${lib.escapeShellArg (kvPath gen file)} > /dev/null 2>&1; then
              all_files_missing=false
              found_files="$found_files  ${lib.escapeShellArg (kvPath gen file)}\n"
            else
              all_files_present=false
              missing_files="$missing_files  ${lib.escapeShellArg (kvPath gen file)}\n"
            fi
          '') (lib.attrValues gen.files)}

          cleanup=""
          trap 'eval "$cleanup"' EXIT

          out=$(mktemp -d)
          cleanup="rm -rf '$out'; $cleanup"
          export out

          if [ "$all_files_missing" = false ] && [ "$all_files_present" = false ]; then
            echo "Inconsistent state for generator: ${gen.name}"
            echo "The following secrets were found:"
            printf "%b" "$found_files"
            echo "The following secrets were missing:"
            printf "%b" "$missing_files"
            echo "You can try purging the secrets for this generator at mount '${cfg.mount}' after making sure they contain nothing you want to keep"
            exit 1
          fi
          if [ "$all_files_present" = true ]; then
            echo "All secrets for ${gen.name} are present"
          elif [ "$all_files_missing" = true ]; then
            prompts=$(mktemp -d)
            cleanup="rm -rf '$prompts'; $cleanup"
            export prompts
            ${lib.concatMapStringsSep "\n" (prompt: ''
              echo ${lib.escapeShellArg prompt.description}
              ${promptCmd.${prompt.type}}
              echo -n "$prompt_value" > "$prompts"/${prompt.name}
            '') (lib.attrValues gen.prompts)}
            echo "Generating vars for ${gen.name}"
          fi

          # dependencies: fetch from OpenBao into $in
          in=$(mktemp -d)
          cleanup="rm -rf '$in'; $cleanup"
          export in
          ${lib.concatMapStringsSep "\n" (dep: ''
            mkdir -p "$in"/${dep}
            ${lib.concatMapStringsSep "\n" (file: ''
              bao kv get \
                -mount=${lib.escapeShellArg cfg.mount} \
                -field=content \
                ${lib.escapeShellArg "${cfg.prefix}/${if file.secret then "secret" else "public"}/${dep}/${file.name}"} \
                | base64 -d > "$in"/${dep}/${file.name}
            '') (lib.attrValues config.vars.generators.${dep}.files)}
          '') gen.dependencies}

          # templates
          templates=$(mktemp -d)
          cleanup="rm -rf '$templates'; $cleanup"
          export templates
          ${lib.concatMapStringsSep "\n" (file: ''
            cp ${lib.escapeShellArg (toString file.template)} "$templates"/${file.name}
          '') templates}

          # generate if all files are missing or we have templates to re-render
          # shellcheck disable=SC2078
          if [ "$all_files_missing" = true ] || [ "${lib.concatMapStringsSep "" (file: file.name) templates}" ]; then
            (
              unset PATH
              ${lib.optionalString (gen.runtimeInputs != [ ]) ''
                PATH=${lib.makeBinPath gen.runtimeInputs}
                export PATH
              ''}
              ${gen.script}
            )

            ${lib.concatMapStringsSep "\n" (file: ''
              if ! test -e "$out"/${file.name}; then
                echo 'generator ${gen.name} failed to generate ${file.name}'
                exit 1
              fi
            '') (lib.attrValues gen.files)}

            # upload to OpenBao (base64 to preserve binary content)
            ${lib.concatMapStringsSep "\n" (file: ''
              bao kv put \
                -mount=${lib.escapeShellArg cfg.mount} \
                ${lib.escapeShellArg (kvPath gen file)} \
                content="$(base64 < "$out"/${file.name})"
            '') (lib.attrValues gen.files)}
          fi

          rm -rf "$out"
        ''
      ) sortedGenerators}
    '';
  };

  # Runs at boot: pulls all secrets from OpenBao and writes them to tmpDir.
  fetch-vars = pkgs.writeShellApplication {
    name = "fetch-vars";
    runtimeInputs = [
      pkgs.openbao
      pkgs.coreutils
    ];
    text = ''
      set -efuo pipefail

      # Set default permissions to only allow the owner to read/write
      umask 077

      ${authEnv}

      ${lib.concatMapStringsSep "\n" (
        gen:
        lib.concatMapStringsSep "\n" (file: ''
          mkdir -p ${
            lib.escapeShellArg "${cfg.tmpDir}/${if file.secret then "secret" else "public"}/${gen.name}"
          }
          bao kv get \
            -mount=${lib.escapeShellArg cfg.mount} \
            -field=content \
            ${lib.escapeShellArg (kvPath gen file)} \
            | base64 -d > ${
              lib.escapeShellArg "${cfg.tmpDir}/${if file.secret then "secret" else "public"}/${gen.name}/${file.name}"
            }
          chown ${file.owner}:${file.group} ${
            lib.escapeShellArg "${cfg.tmpDir}/${if file.secret then "secret" else "public"}/${gen.name}/${file.name}"
          }
          chmod ${file.mode} ${
            lib.escapeShellArg "${cfg.tmpDir}/${if file.secret then "secret" else "public"}/${gen.name}/${file.name}"
          }
        '') (lib.attrValues gen.files)
      ) sortedGenerators}
    '';
  };
in
{
  options.vars.settings.openbao = {
    enable = lib.mkEnableOption "OpenBao vars backend";

    address = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8200";
      description = "OpenBao server address (VAULT_ADDR compatible).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Path to a file containing the OpenBao token.
        The token must have read/write access to the configured KV mount.
        For the generate step the token needs write access; for the fetch
        service at boot it only needs read access, so you can use two
        different policies/tokens if desired.
      '';
    };

    mount = lib.mkOption {
      type = lib.types.str;
      default = "secret";
      description = "KV v2 mount point in OpenBao.";
    };

    prefix = lib.mkOption {
      type = lib.types.str;
      default = "vars";
      description = "Path prefix within the KV mount used for all vars entries.";
    };

    tmpDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/vars";
      description = ''
        Directory where fetched secrets are written at boot.
        This should be on a tmpfs so secrets are not persisted across reboots.
        Defaults to /run/vars which is already on tmpfs on NixOS.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    vars.settings.fileModule = file: {
      path = "${cfg.tmpDir}/${if file.config.secret then "secret" else "public"}/${file.config.generator}/${file.config.name}";
    };

    environment.systemPackages = [ generate-vars ];
    system.build.generate-vars = generate-vars;

    systemd.services.fetch-vars = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      before = [ "default.target" ];
      description = "Fetch secrets from OpenBao";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${fetch-vars}/bin/fetch-vars";
      };
    };
  };
}
