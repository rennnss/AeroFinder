#!/bin/bash

# macOS Blur Tweak - Quick Install Script

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║           macOS Blur Tweak - Installation                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ Error: This script must be run on macOS"
    exit 1
fi

# Check if Ammonia is installed
if [ ! -d "/var/ammonia" ]; then
    echo "⚠️  Warning: Ammonia injection system not found at /var/ammonia"
    echo ""
    echo "Please install Ammonia first:"
    echo "  git clone https://github.com/CoreBedtime/ammonia"
    echo "  cd ammonia"
    echo "  ./install.sh"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for required security settings
echo "🔍 Checking security settings..."

# Check SIP status
SIP_STATUS=$(csrutil status 2>&1 || echo "unknown")
if [[ "$SIP_STATUS" == *"enabled"* ]]; then
    echo "⚠️  System Integrity Protection (SIP) is ENABLED"
    echo "   The tweak requires SIP to be disabled."
    echo ""
    echo "   To disable SIP:"
    echo "   1. Boot into Recovery Mode"
    echo "   2. Open Terminal"
    echo "   3. Run: csrutil disable"
    echo "   4. Restart"
    echo ""
fi

cd "$SCRIPT_DIR"

echo "🔨 Building blur tweak..."
make clean
make

echo ""
echo "📦 Installing blur tweak..."
sudo make install

echo ""
echo "✅ Installation complete!"
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    Usage Examples                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Enable blur effects:"
echo "  blurctl on"
echo ""
echo "Configure transparent titlebars:"
echo "  blurctl --titlebar on"
echo ""
echo "Enable vibrancy for text:"
echo "  blurctl --vibrancy on"
echo ""
echo "Emphasize focused windows:"
echo "  blurctl --emphasize on"
echo ""
echo "Adjust blur intensity:"
echo "  blurctl --intensity 75"
echo ""
echo "Test with sample apps:"
echo "  make test"
echo ""
echo "For more information, see README.md"
echo ""

read -p "Would you like to test the tweak now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "🚀 Testing blur tweak..."
    make test
    echo ""
    echo "✨ Test apps have been restarted with blur effects!"
    echo "   Try focusing different windows to see emphasis effects."
fi

echo ""
echo "Done! 🎉"
