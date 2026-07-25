import re

PKG = '/sandbox/workspace/.openclaw/extensions/mlflow-openclaw/node_modules/@mlflow/mlflow-openclaw'

SVC = PKG + '/src/service.ts'
with open(SVC, 'r') as f:
    content = f.read()
if 'diagnostics-otel' in content:
    old_import = re.compile(
        r"import\s*\{[^}]*onDiagnosticEvent[^}]*\}\s*from\s*['\"]openclaw/plugin-sdk/diagnostics-otel['\"];",
        re.DOTALL
    )
    replacement = ('// diagnostics-otel replaced with no-op (not available in OpenClaw 2026.7.1)\n'
                   'const onDiagnosticEvent = (fn: any) => (() => {});\n'
                   'type DiagnosticEventPayload = any;')
    content = old_import.sub(replacement, content)
    with open(SVC, 'w') as f:
        f.write(content)
    print('service.ts patched')
else:
    print('service.ts already patched')

IDX = PKG + '/index.ts'
with open(IDX, 'r') as f:
    content = f.read()
if 'definePluginEntry' in content:
    content = content.replace(
        "import { definePluginEntry, type OpenClawPluginApi } from 'openclaw/plugin-sdk/plugin-entry';",
        '// definePluginEntry replaced for OpenClaw 2026.7.1 compat'
    )
    content = re.sub(r'export\s+default\s+definePluginEntry\(\{', 'const mlflowPlugin = ({', content)
    content = content.replace('OpenClawPluginApi', 'any')
    if not content.rstrip().endswith('export default mlflowPlugin;'):
        content = content.rstrip()
        if content.endswith('});'):
            content = content[:-3] + '});\nexport default mlflowPlugin;\n'
    with open(IDX, 'w') as f:
        f.write(content)
    print('index.ts patched')
else:
    print('index.ts already patched')

# Backport of mlflow/mlflow#23927 for the pinned @mlflow/core@0.2.0 (see the
# comment above this heredoc, and constraint #4b in docs/constraints.md).
# createOssAuth()'s headersProvider builds Content-Type/Authorization but
# never X-MLFLOW-WORKSPACE — RHOAI-managed MLflow (ADR-0017) rejects every
# request without it once workspaces are enabled, even with valid auth.
CORE_AUTH = '/sandbox/workspace/.openclaw/extensions/mlflow-openclaw/node_modules/@mlflow/core/dist/auth/index.js'
with open(CORE_AUTH, 'r') as f:
    content = f.read()
if 'X-MLFLOW-WORKSPACE' in content:
    print('@mlflow/core auth/index.js already patched')
else:
    old = """    const headersProvider = async () => {
        const headers = { 'Content-Type': 'application/json' };
        if (authHeader) {
            headers['Authorization'] = authHeader;
        }
        return headers;
    };"""
    new = """    const headersProvider = async () => {
        const headers = { 'Content-Type': 'application/json' };
        if (authHeader) {
            headers['Authorization'] = authHeader;
        }
        // Backport of mlflow/mlflow#23927 (upstream fix landed in
        // @mlflow/core@0.3.0; this plugin is pinned to 0.2.0 — see
        // docs/constraints.md #4b). Required by RHOAI-managed MLflow
        // whenever workspaces are enabled (docs/adrs/ADR-0017-rhoai-mlflow-scope.md).
        const workspace = options.workspace || process.env.MLFLOW_WORKSPACE;
        if (workspace) {
            headers['X-MLFLOW-WORKSPACE'] = workspace;
        }
        return headers;
    };"""
    if old not in content:
        raise SystemExit(
            '@mlflow/core auth/index.js: expected headersProvider block not found '
            '(package version drift?) — refusing to patch blindly. Inspect ' + CORE_AUTH
        )
    content = content.replace(old, new)
    with open(CORE_AUTH, 'w') as f:
        f.write(content)
    print('@mlflow/core auth/index.js patched (X-MLFLOW-WORKSPACE backport)')
