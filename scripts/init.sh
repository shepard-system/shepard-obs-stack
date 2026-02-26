#!/bin/bash
# scripts/init.sh
# Bootstrap script for local observability stack

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          Shepherd Observability - Local Bootstrap             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check prerequisites
echo "→ Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    echo "✗ Docker not found. Please install Docker first."
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "✗ Docker Compose (v2) not found. Please update Docker."
    exit 1
fi

echo "✓ Docker and Docker Compose found"
echo ""

# Create .env if it doesn't exist
if [ ! -f .env ]; then
    echo "→ Creating .env from .env.example..."
    cp .env.example .env
    echo "✓ .env created. Please review and update if needed."
    echo ""
else
    echo "✓ .env already exists"
    echo ""
fi

# Start the stack
echo "→ Starting observability stack..."
docker compose up -d

echo ""
echo "→ Waiting for services to be healthy..."
docker compose up --wait -d 2>/dev/null || sleep 15

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                      Service Status                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"

docker compose ps

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                      Access URLs                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Grafana:          http://localhost:3000"
echo "    └─ User: admin, Password: shepherd (default)"
echo ""
echo "  Prometheus:       http://localhost:9090"
echo "  Loki:             http://localhost:3100"
echo "  Tempo:            http://localhost:3200"
echo ""
echo "  OTel Collector:"
echo "    └─ OTLP gRPC:   localhost:4317"
echo "    └─ OTLP HTTP:   localhost:4318"
echo "    └─ Metrics:     http://localhost:8888/metrics"
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                      Next Steps                              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "  1. Open Grafana at http://localhost:3000"
echo "  2. Verify datasources are connected (Prometheus, Loki, Tempo)"
echo "  3. Install CLI hooks: ./hooks/install.sh"
echo "  4. Check logs: docker compose logs -f <service>"
echo ""

echo "✓ Bootstrap complete!"
echo ""
