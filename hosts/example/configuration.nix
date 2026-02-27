{ config, lib, pkgs, ... }:
{
  services.openclaw = {
    enable = true;

    # You will likely override this to the specific openclaw package you want.
    # package = pkgs.openclaw-gateway;

    settings = {
      # Minimal non-secret config. Fill this out for your deployment.
      gateway = {
        port = 18789;
        mode = "local";
        bind = "loopback";
      };

      models = {
        mode = "merge";
        providers = {
          mission-control = {
            baseUrl = "http://127.0.0.1:4000/v1";
            api = "openai-completions";
            models = [
              { id = "openclaw-planner"; name = "Planner"; contextWindow = 128000; }
              { id = "openclaw-coder"; name = "Coder"; contextWindow = 128000; }
            ];
          };
        };
      };

      agents.defaults.model.primary = "mission-control/openclaw-planner";
      agents.defaults.workspace = "/var/lib/openclaw/.openclaw/workspace";
    };
  };
}
