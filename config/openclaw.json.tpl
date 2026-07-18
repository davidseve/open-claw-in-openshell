{
  "models": {
    "providers": {
      "maas": {
        "baseUrl": "https://maas-rhdp.apps.maas.redhatworkshops.io/v1",
        "apiKey": "openshell:resolve:env:LITELLM_API_KEY",
        "api": "openai-completions",
        "models": [
          {
            "id": "claude-sonnet-4-6",
            "name": "Claude Sonnet 4.6",
            "reasoning": true,
            "input": ["text", "image"],
            "contextWindow": 200000,
            "maxTokens": 64000,
            "compat": { "supportsStore": false }
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": { "primary": "maas/claude-sonnet-4-6" },
      "workspace": "/sandbox/workspace"
    }
  },
  "tools": {
    "deny": ["gateway", "cron", "openclaw"],
    "fs": { "workspaceOnly": true }
  },
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": 18789,
    "auth": {
      "mode": "trusted-proxy",
      "trustedProxy": {
        "userHeader": "x-forwarded-user"
      }
    },
    "trustedProxies": ["127.0.0.1", "::1"],
    "controlUi": {
      "allowedOrigins": [
        "https://openclaw-ui.__APPS_DOMAIN__",
        "https://openclaw-gw--openclaw-ui.__APPS_DOMAIN__"
      ]
    },
    "http": {
      "endpoints": {
        "chatCompletions": { "enabled": false }
      }
    }
  }
}
