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
