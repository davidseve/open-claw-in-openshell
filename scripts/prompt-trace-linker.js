// Sidecar that links MLflow Prompt Registry versions to traces.
//
// Reads .prompt-versions.json once at startup, then periodically
// queries MLflow for unlinked traces and creates native prompt-trace
// associations via the mlflow.linkedPrompts tag and LinkPromptsToTrace API.
//
// Uses curl for HTTP requests because the OpenShell sandbox proxy
// enforces binary-level L7 policy that allows /usr/bin/curl but
// blocks direct HTTP from Node.js processes.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const MLFLOW_URL =
  process.env.MLFLOW_URL || "http://mlflow.observability.svc:5000";
const WORKSPACE = process.env.OPENCLAW_WORKSPACE_DIR || "/sandbox/workspace";
const EXPERIMENT_ID = process.env.MLFLOW_EXPERIMENT_ID || "0";
const POLL_INTERVAL_MS = parseInt(process.env.LINKER_POLL_MS || "30000", 10);
const LINKED_PROMPTS_TAG = "mlflow.linkedPrompts";

let promptRefs = null;
let linkedPromptsTagValue = null;
let promptSummary = null;

function loadManifest() {
  const manifestPath = path.join(WORKSPACE, ".prompt-versions.json");
  try {
    const raw = fs.readFileSync(manifestPath, "utf-8");
    const manifest = JSON.parse(raw);
    promptRefs = [];
    const summary = {};
    for (const [shortName, info] of Object.entries(manifest.prompts || {})) {
      promptRefs.push({
        name: info.name,
        version: String(info.version),
      });
      summary[shortName] = `v${info.version}`;
    }
    linkedPromptsTagValue = JSON.stringify(promptRefs);
    promptSummary = JSON.stringify(summary);
    console.log(
      `[linker] Loaded ${promptRefs.length} prompts: ${promptRefs.map((p) => `${p.name}@${p.version}`).join(", ")}`,
    );
  } catch (err) {
    console.error(`[linker] Cannot read manifest: ${err.message}`);
    process.exit(1);
  }
}

function curlGet(urlPath) {
  try {
    const out = execFileSync("/usr/bin/curl", [
      "-sf",
      "--max-time", "10",
      `${MLFLOW_URL}${urlPath}`,
    ], { encoding: "utf-8", timeout: 15000 });
    return { status: 200, body: out };
  } catch (err) {
    return { status: err.status || 500, body: err.stderr || err.message };
  }
}

function curlPatch(urlPath, data) {
  try {
    const out = execFileSync("/usr/bin/curl", [
      "-sf",
      "--max-time", "10",
      "-X", "PATCH",
      "-H", "Content-Type: application/json",
      "-d", JSON.stringify(data),
      `${MLFLOW_URL}${urlPath}`,
    ], { encoding: "utf-8", timeout: 15000 });
    return { status: 200, body: out };
  } catch (err) {
    return { status: err.status || 500, body: err.stderr || err.message };
  }
}

function curlPost(urlPath, data) {
  try {
    const out = execFileSync("/usr/bin/curl", [
      "-sf",
      "--max-time", "10",
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", JSON.stringify(data),
      `${MLFLOW_URL}${urlPath}`,
    ], { encoding: "utf-8", timeout: 15000 });
    return { status: 200, body: out };
  } catch (err) {
    return { status: err.status || 500, body: err.stderr || err.message };
  }
}

function linkUnlinkedTraces() {
  try {
    const searchResp = curlGet(
      `/api/2.0/mlflow/traces?experiment_ids=${EXPERIMENT_ID}&max_results=50`,
    );

    if (searchResp.status !== 200) {
      if (searchResp.body.includes("404") || searchResp.body.includes("400")) return;
      console.error(
        `[linker] Search failed: ${searchResp.status} ${String(searchResp.body).slice(0, 200)}`,
      );
      return;
    }

    const data = JSON.parse(searchResp.body);
    const traces = data.traces || [];
    let linked = 0;

    for (const trace of traces) {
      const requestId = trace.request_id;
      if (!requestId) continue;

      const tags = trace.tags || [];
      const alreadyLinked = tags.some((t) => t.key === LINKED_PROMPTS_TAG);
      if (alreadyLinked) continue;

      // Set mlflow.linkedPrompts tag (populates "Prompt" column in UI)
      const tagResp = curlPatch(
        `/api/2.0/mlflow/traces/${requestId}/tags`,
        { key: LINKED_PROMPTS_TAG, value: linkedPromptsTagValue },
      );

      if (tagResp.status !== 200) {
        console.error(
          `[linker] Failed to tag ${requestId}: ${String(tagResp.body).slice(0, 200)}`,
        );
        continue;
      }

      // Custom tag visible in trace detail view (mlflow.* tags are hidden)
      try {
        curlPatch(
          `/api/2.0/mlflow/traces/${requestId}/tags`,
          { key: "prompt_versions", value: promptSummary },
        );
      } catch (_) {}

      // Entity links via link-prompts API
      try {
        curlPost(`/api/2.0/mlflow/traces/link-prompts`, {
          trace_id: requestId,
          prompt_versions: promptRefs,
        });
      } catch (_) {}

      linked++;
      console.log(`[linker] Linked trace ${requestId}`);
    }

    if (linked > 0) {
      console.log(`[linker] Linked ${linked} traces this cycle`);
    }
  } catch (err) {
    if (String(err).includes("ECONNREFUSED") || String(err).includes("ENOTFOUND")) return;
    console.error(`[linker] Error: ${err.message || err}`);
  }
}

loadManifest();
console.log(
  `[linker] Starting (poll every ${POLL_INTERVAL_MS / 1000}s, experiment=${EXPERIMENT_ID})`,
);

linkUnlinkedTraces();
const timer = setInterval(linkUnlinkedTraces, POLL_INTERVAL_MS);

process.on("SIGTERM", () => {
  clearInterval(timer);
  console.log("[linker] Shutting down");
  process.exit(0);
});

process.on("SIGINT", () => {
  clearInterval(timer);
  process.exit(0);
});
