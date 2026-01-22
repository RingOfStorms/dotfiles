{
  config,
  lib,
  inputs,
  ...
}:
let
  name = "litellm-public";

  hostDataDir = "/var/lib/${name}";

  hostAddress = "10.0.0.1";
  containerAddress = "10.0.0.4";
  hostAddress6 = "fc00::1";
  containerAddress6 = "fc00::4";

  litellmNixpkgs = inputs.litellm-nixpkgs;
  pkgsLitellm = import litellmNixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };

  containerPort = 4000;
  externalPort = 8095;

  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;

  binds = [
    {
      host = "${hostDataDir}/postgres";
      container = "/var/lib/postgresql/17";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
    {
      host = "${hostDataDir}/backups/postgres";
      container = "/var/backup/postgresql";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
  ]
  ++ lib.optionals (hasSecret "litellm_public_master_key") [
    {
      host = config.age.secrets.litellm_public_master_key.path;
      container = "/var/secrets/litellm_master_key";
      readOnly = true;
    }
  ];

  bindsWithUsers = lib.filter (b: b ? user) binds;
  uniqueUsers = lib.foldl' (
    acc: bind: if lib.lists.any (item: item.user == bind.user) acc then acc else acc ++ [ bind ]
  ) [ ] bindsWithUsers;

  users = {
    users = lib.listToAttrs (
      lib.map (u: {
        name = u.user;
        value = {
          isSystemUser = true;
          name = u.user;
          uid = u.uid;
          group = u.user;
        };
      }) uniqueUsers
    );

    groups = lib.listToAttrs (
      lib.map (g: {
        name = g.user;
        value.gid = g.gid;
      }) uniqueUsers
    );
  };

  azureModels = [
    "gpt-5.2-2025-12-11"
    "gpt-5.1-2025-11-13"
    "gpt-4o-2024-05-13"
    "gpt-4.1-2025-04-14"
    "gpt-4.1-mini-2025-04-14"
    "gpt-5-nano-2025-08-07"
    "gpt-5-mini-2025-08-07"
    "gpt-5-2025-08-07"
  ];

  azureReasoningAliases = [
    {
      model_name = "azure-gpt-5.2-low";
      litellm_params = {
        model = "azure/gpt-5.2-2025-12-11";
        api_base = "http://100.64.0.8:9010/azure";
        api_version = "2025-04-01-preview";
        api_key = "na";
        extra_body = {
          reasoning_effort = "low";
        };
      };
    }
    {
      model_name = "azure-gpt-5.2-medium";
      litellm_params = {
        model = "azure/gpt-5.2-2025-12-11";
        api_base = "http://100.64.0.8:9010/azure";
        api_version = "2025-04-01-preview";
        api_key = "na";
        extra_body = {
          reasoning_effort = "medium";
        };
      };
    }
    {
      model_name = "azure-gpt-5.2-high";
      litellm_params = {
        model = "azure/gpt-5.2-2025-12-11";
        api_base = "http://100.64.0.8:9010/azure";
        api_version = "2025-04-01-preview";
        api_key = "na";
        extra_body = {
          reasoning_effort = "high";
        };
      };
    }
  ];

in
{
  options = { };
  config = {
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ externalPort ];

    services.nginx.virtualHosts."litellm-public" = {
      listen = [
        {
          addr = "0.0.0.0";
          port = externalPort;
        }
      ];
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://${containerAddress}:${toString containerPort}";
        };
      };
    };

    inherit users;

    system.activationScripts."createDirsFor${name}" = ''
      ${lib.concatStringsSep "\n" (
        lib.map (bind: ''
          mkdir -p ${bind.host}
          chown -R ${toString bind.user}:${toString bind.gid} ${bind.host}
          chmod -R 750 ${bind.host}
        '') bindsWithUsers
      )}
    '';

    containers.${name} = {
      ephemeral = true;
      autoStart = true;
      privateNetwork = true;
      hostAddress = hostAddress;
      localAddress = containerAddress;
      hostAddress6 = hostAddress6;
      localAddress6 = containerAddress6;
      bindMounts = lib.foldl (
        acc: bind:
        {
          "${bind.container}" = {
            hostPath = bind.host;
            isReadOnly = bind.readOnly or false;
          };
        }
        // acc
      ) { } binds;
      nixpkgs = litellmNixpkgs;
      config =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        {
          config = {
            system.stateVersion = "25.05";

            networking = {
              firewall = {
                enable = true;
                allowedTCPPorts = [ containerPort ];
              };
              useHostResolvConf = lib.mkForce false;
            };
            services.resolved.enable = true;

            inherit users;

            services.postgresql = {
              enable = true;
              package = pkgs.postgresql_17.withJIT;
              enableJIT = true;
              authentication = ''
                local all all trust
                host all all 127.0.0.1/8 trust
                host all all ::1/128 trust
              '';
              ensureDatabases = [ "litellm" ];
              ensureUsers = [
                {
                  name = "litellm";
                  ensureDBOwnership = true;
                  ensureClauses.login = true;
                }
              ];
            };

            services.postgresqlBackup = {
              enable = true;
            };

            systemd.services.litellm = {
              description = "LiteLLM Public Proxy";
              after = [
                "network.target"
                "postgresql.service"
              ];
              requires = [ "postgresql.service" ];
              wantedBy = [ "multi-user.target" ];

              environment = {
                DATABASE_URL = "postgresql://litellm@/litellm?host=/var/run/postgresql";
                SCARF_NO_ANALYTICS = "True";
                DO_NOT_TRACK = "True";
                ANONYMIZED_TELEMETRY = "False";
              };

              script = ''
                export LITELLM_MASTER_KEY="$(cat /var/secrets/litellm_master_key)"
                exec ${pkgsLitellm.litellm}/bin/litellm --config /etc/litellm/config.yaml --host 0.0.0.0 --port ${toString containerPort}
              '';

              serviceConfig = {
                Type = "simple";
                User = "litellm";
                Group = "litellm";
                Restart = "always";
                RestartSec = 5;
              };
            };

            users.users.litellm = {
              isSystemUser = true;
              group = "litellm";
              extraGroups = [ "keys" ];
            };
            users.groups.litellm = { };
            users.groups.keys = { };

            environment.etc."litellm/config.yaml".text = builtins.toJSON {
              general_settings = {
                master_key = "os.environ/LITELLM_MASTER_KEY";
                database_url = "os.environ/DATABASE_URL";
              };
              litellm_settings = {
                check_provider_endpoints = true;
                drop_params = true;
                modify_params = true;
              };
              model_list =
                (builtins.map (m: {
                  model_name = "azure-${m}";
                  litellm_params = {
                    model = "azure/${m}";
                    api_base = "http://100.64.0.8:9010/azure";
                    api_version = "2025-04-01-preview";
                    api_key = "na";
                  };
                }) azureModels)
                ++ azureReasoningAliases;
            };
          };
        };
    };
  };
}
