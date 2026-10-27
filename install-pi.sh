#!/usr/bin/env bash
# Install only the pi integration; never rebuild teams or touch login services.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
mkdir -p "$PI_DIR/extensions"
python3 - "$HERE" "$PI_DIR/extensions/team.ts" <<'PY'
import json, os, sys
repo, dst = sys.argv[1:]
text = ('import extension from ' + json.dumps(repo + '/pi-extension.ts') + ';\n'
        'import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";\n'
        'export default function (pi: ExtensionAPI) { extension(pi, ' + json.dumps(repo) + '); }\n')
with open(dst + '.new', 'w') as fh:
    fh.write(text)
os.replace(dst + '.new', dst)
PY
printf 'Installed %s/extensions/team.ts. Run /reload in pi.\n' "$PI_DIR"
