#!/usr/bin/env bash

# ==============================================================================
# Raspberry Pi 5 Local Coding LLM Setup Script
# ==============================================================================

set -e

# Terminal colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Raspberry Pi 5 Local LLM Setup Starting ===${NC}\n"

# 1. Architecture Check
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo -e "${RED}[ERROR] 64-bit OS required (aarch64). Detected: $ARCH${NC}"
    exit 1
fi

# 2. System Package Updates & Dependencies
echo -e "${YELLOW}[1/5] Updating system packages and installing prerequisites...${NC}"
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git build-essential zstd jq htop

# 3. Install Ollama Backend
echo -e "${YELLOW}[2/5] Installing Ollama engine...${NC}"
if command -v ollama &> /dev/null; then
    echo -e "${GREEN}Ollama is already installed. Updating to latest...${NC}"
fi
curl -fsSL https://ollama.com/install.sh | sh

# Enable and start background daemon
echo -e "${YELLOW}[3/5] Starting Ollama systemd background service...${NC}"
sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl restart ollama

# Wait for Ollama service to respond
echo -n "Waiting for Ollama service to initialize..."
until curl -s http://localhost:11434/api/tags > /dev/null; do
    echo -n "."
    sleep 2
done
echo -e "\n${GREEN}Ollama service active on http://localhost:11434${NC}"

# 4. Pull Coding Models
echo -e "${YELLOW}[4/5] Downloading models (this may take a few minutes)...${NC}"

MODELS=(
    "qwen2.5-coder:1.5b" # Ultra-fast tab autocomplete
    "qwen2.5-coder:3b"   # Primary daily driver
    "qwen2.5-coder:7b"   # Complex reasoning and refactoring
)

for MODEL in "${MODELS[@]}"; do
    echo -e "${BLUE}Downloading ${MODEL}...${NC}"
    ollama pull "$MODEL"
done

# 5. Generate VS Code Continue.dev Configuration
echo -e "${YELLOW}[5/5] Generating VS Code Continue.dev settings file...${NC}"
CONTINUE_DIR="$HOME/.continue"
mkdir -p "$CONTINUE_DIR"

cat << 'EOF' > "$CONTINUE_DIR/config.json"
{
  "models": [
    {
      "title": "Qwen2.5-Coder 3B (Daily Driver)",
      "provider": "ollama",
      "model": "qwen2.5-coder:3b",
      "apiBase": "http://localhost:11434"
    },
    {
      "title": "Qwen2.5-Coder 7B (Deep Reasoning)",
      "provider": "ollama",
      "model": "qwen2.5-coder:7b",
      "apiBase": "http://localhost:11434"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen2.5-Coder 1.5B Autocomplete",
    "provider": "ollama",
    "model": "qwen2.5-coder:1.5b",
    "apiBase": "http://localhost:11434"
  }
}
EOF

echo -e "${GREEN}Config created at $CONTINUE_DIR/config.json${NC}\n"

echo -e "${GREEN}=== Setup Complete! ===${NC}"
echo -e "Installed models ready for local execution:"
ollama list

echo -e "\n${BLUE}How to start using:${NC}"
echo -e "1. Run directly in terminal: ${YELLOW}ollama run qwen2.5-coder:3b${NC}"
echo -e "2. Open VS Code, install the extension ${YELLOW}Continue${NC}, and it will automatically attach to your local models."