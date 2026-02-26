#!/usr/bin/env bash
# Render C4 PlantUML diagrams to SVG using Docker.
# Usage: ./scripts/render-c4.sh
#
# Requires: Docker
# Produces: docs/c4/*.svg alongside the existing .puml sources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
C4_DIR="$PROJECT_ROOT/docs/c4"

if ! command -v docker &>/dev/null; then
    echo "Error: docker is not installed or not in PATH" >&2
    exit 1
fi

puml_files=("$C4_DIR"/*.puml)
if [ ${#puml_files[@]} -eq 0 ]; then
    echo "No .puml files found in $C4_DIR"
    exit 0
fi

echo "Rendering ${#puml_files[@]} diagrams to SVG..."

docker run --rm \
    -v "$C4_DIR":/data \
    plantuml/plantuml \
    -tsvg /data/*.puml

echo "Done. SVG files:"
ls -1 "$C4_DIR"/*.svg
