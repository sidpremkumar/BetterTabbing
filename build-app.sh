#!/bin/bash

# BetterTabbing Build & Package Script
# Usage: ./build-app.sh

set -e  # Exit on any error

# Configuration
APP_NAME="BetterTabbing"
BUNDLE_ID="com.sparechange.BetterTabbing"
VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_MACOS="13.0"
SIGNING_IDENTITY="Developer ID Application: SpareChange Incorporated (NYC) (TD6ZPWX7QD)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  Building ${APP_NAME} v${VERSION}${NC}"
echo -e "${YELLOW}========================================${NC}"

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Clean previous build
echo -e "\n${YELLOW}[1/6] Cleaning previous build...${NC}"
rm -rf "${APP_NAME}.app"
rm -rf "${APP_NAME}.zip"

# Build release
echo -e "\n${YELLOW}[2/6] Building release version...${NC}"
swift build -c release

if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi
echo -e "${GREEN}Build successful!${NC}"

# Create app bundle structure
echo -e "\n${YELLOW}[3/6] Creating app bundle structure...${NC}"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

# Copy binary
echo -e "\n${YELLOW}[4/6] Copying binary...${NC}"
cp ".build/release/${APP_NAME}" "${APP_NAME}.app/Contents/MacOS/"

# Create Info.plist
echo -e "\n${YELLOW}[5/6] Creating Info.plist...${NC}"
cat > "${APP_NAME}.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024 SpareChange Incorporated. All rights reserved.</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "${APP_NAME}.app/Contents/PkgInfo"

# Generate app icon
echo -e "\n${YELLOW}[6/7] Generating app icon...${NC}"
swift generate-icon.swift

if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "${APP_NAME}.app/Contents/Resources/"
    echo -e "${GREEN}App icon created!${NC}"
else
    echo -e "${YELLOW}Warning: Could not generate app icon${NC}"
fi

# Code sign
echo -e "\n${YELLOW}[7/7] Code signing...${NC}"
codesign --force --deep --sign "${SIGNING_IDENTITY}" "${APP_NAME}.app"

if [ $? -ne 0 ]; then
    echo -e "${RED}Code signing failed!${NC}"
    exit 1
fi

# Verify signature
echo -e "\n${YELLOW}Verifying signature...${NC}"
codesign --verify --verbose "${APP_NAME}.app"

if [ $? -ne 0 ]; then
    echo -e "${RED}Signature verification failed!${NC}"
    exit 1
fi

echo -e "${GREEN}Signature verified!${NC}"

# Create zip for distribution
echo -e "\n${YELLOW}Creating distribution zip...${NC}"
zip -r "${APP_NAME}.zip" "${APP_NAME}.app"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "\nApp bundle: ${SCRIPT_DIR}/${APP_NAME}.app"
echo -e "Distribution zip: ${SCRIPT_DIR}/${APP_NAME}.zip"
echo -e "\nTo install, run:"
echo -e "  cp -r ${APP_NAME}.app /Applications/"
echo -e "\nTo test, run:"
echo -e "  open ${APP_NAME}.app"
