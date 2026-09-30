#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Assets.xcassets/AppIcon.appiconset
cp AppIcon.png Assets.xcassets/AppIcon.appiconset/AppIcon.png
cat > Assets.xcassets/Contents.json <<'JSON'
{"info":{"author":"xcode","version":1}}
JSON
cat > Assets.xcassets/AppIcon.appiconset/Contents.json <<'JSON'
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
JSON
xcodegen generate --spec project.yml
