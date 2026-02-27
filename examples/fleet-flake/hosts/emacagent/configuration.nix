{ config, pkgs, ... }:
{
  # Example only. In your real fleet repo, add agenix secrets and pass them in:
  # age.secrets.openclaw-mission-control-api-key.file = ../secrets/openclaw-mission-control-api-key.age;

  services.openclaw = {
    enable = true;

    # settings is written to openclaw.json in the nix store; keep it non-secret.
    settings = {
      gateway = {
        port = 18789;
        mode = "local";
        bind = "loopback";
      };

      models = {
        mode = "merge";
        providers.mission-control = {
          baseUrl = "http://100.73.207.15:4000/v1";
          api = "openai-completions";
          models = [
            { id = "openclaw-planner"; name = "Planner"; contextWindow = 128000; }
          ];
        };
      };

      agents.defaults.model.primary = "mission-control/openclaw-planner";
      agents.defaults.workspace = "/var/lib/openclaw/.openclaw/workspace";
    };

    # credentials = {
    #   MISSION_CONTROL_API_KEY = config.age.secrets.openclaw-mission-control-api-key.path;
    # };
  };
}
