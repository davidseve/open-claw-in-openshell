{
  "models": {
    "providers": {
      "maas": {
        "baseUrl": "https://maas-rhdp.apps.maas.redhatworkshops.io/v1",
        "apiKey": "__MAAS_API_KEY__",
        "api": "openai-completions",
        "models": [
          {
            "id": "gpt-oss-120b",
            "name": "GPT-OSS 120B",
            "reasoning": true,
            "input": ["text"],
            "contextWindow": 32768,
            "maxTokens": 8192,
            "compat": { "supportsStore": false }
          },
          {
            "id": "llama-scout-17b",
            "name": "Llama Scout 17B",
            "reasoning": false,
            "input": ["text"],
            "contextWindow": 400000,
            "maxTokens": 8192,
            "compat": { "supportsStore": false }
          },
          {
            "id": "claude-sonnet-4-6",
            "name": "Claude Sonnet 4.6 (backup)",
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
      "model": {
        "primary": "maas/gpt-oss-120b",
        "fallbacks": ["maas/llama-scout-17b"]
      },
      "models": {
        "maas/gpt-oss-120b": { "alias": "GPT-OSS" },
        "maas/llama-scout-17b": { "alias": "Scout-fallback" },
        "maas/claude-sonnet-4-6": { "alias": "Sonnet-backup" }
      },
      "workspace": "/sandbox/workspace"
    }
  },
  "tools": {
    "deny": ["gateway", "cron", "openclaw", "browser", "nodes"],
    "fs": { "workspaceOnly": true }
  },
  "plugins": {
    "deny": ["workboard", "admin-http-rpc"],
    "entries": {
      "diagnostics-otel": {
        "enabled": false
      },
      "mlflow-openclaw": {
        "enabled": true,
        "config": {
          "trackingUri": "https://mlflow.redhat-ods-applications.svc:8443",
          "experimentId": "0"
        },
        "hooks": {
          "allowConversationAccess": true
        }
      }
    }
  },
  "diagnostics": {
    "enabled": true,
    "otel": {
      "enabled": true,
      "endpoint": "http://otel-collector.observability.svc:4318",
      "protocol": "http/protobuf",
      "serviceName": "openclaw-agent",
      "traces": false,
      "metrics": true,
      "logs": false,
      "sampleRate": 1.0,
      "captureContent": true
    }
  },
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": 18789,
    "auth": {
      "mode": "trusted-proxy",
      "trustedProxy": {
        "userHeader": "x-forwarded-email",
        "requiredHeaders": ["x-forwarded-proto", "x-forwarded-host"],
        "allowLoopback": true
      }
    },
    "trustedProxies": ["127.0.0.1", "::1", "10.217.0.0/22", "10.217.4.0/23", "192.168.0.0/16"],
    "controlUi": {
      "allowedOrigins": [
        "https://__SANDBOX_NAME__--openclaw-ui.__APPS_DOMAIN__"
      ],
      "dangerouslyDisableDeviceAuth": true
    },
    "terminal": {
      "enabled": false
    },
    "reload": {
      "mode": "off"
    },
    "nodes": {
      "denyCommands": ["system.run", "canvas.navigate"]
    },
    "http": {
      "endpoints": {
        "chatCompletions": { "enabled": false }
      }
    }
  }
}
