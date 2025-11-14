# macOS Blur Tweak Makefile
# Advanced window blending using NSVisualEffectView

# Determine repository root (parent of macos-blur-tweak)
REPO_ROOT := $(shell pwd)

# Compiler detection
XCODE_PATH := $(shell xcode-select -p)
CC := $(shell xcrun -find clang)

# SDK paths
SDKROOT ?= $(shell xcrun --show-sdk-path)
ISYSROOT := $(shell xcrun -sdk macosx --show-sdk-path)

# Compiler flags
CFLAGS = -Wall -Wextra -O2 \
    -fobjc-arc \
    -fmodules \
    -isysroot $(SDKROOT) \
    -iframework $(SDKROOT)/System/Library/Frameworks \
    -F/System/Library/PrivateFrameworks \
    -I$(REPO_ROOT)/ZKSwizzle \
    -Wno-deprecated-declarations \
    -Wno-cast-function-type-mismatch

ARCHS = -arch x86_64 -arch arm64 -arch arm64e
FRAMEWORK_PATH = $(SDKROOT)/System/Library/Frameworks
PRIVATE_FRAMEWORK_PATH = $(SDKROOT)/System/Library/PrivateFrameworks
PUBLIC_FRAMEWORKS = -framework Foundation -framework AppKit -framework QuartzCore \
    -framework Cocoa -framework CoreFoundation

# Project settings
PROJECT = blur_tweak
DYLIB_NAME = lib$(PROJECT).dylib
BUILD_DIR = build
SOURCE_DIR = src
INSTALL_DIR = /var/ammonia/core/tweaks

# Source files
DYLIB_SOURCES = $(SOURCE_DIR)/blurtweak.m $(REPO_ROOT)/ZKSwizzle/ZKSwizzle.m
DYLIB_OBJECTS = $(BUILD_DIR)/src/blurtweak.o $(BUILD_DIR)/ZKSwizzle/ZKSwizzle.o

# Installation paths
INSTALL_PATH = $(INSTALL_DIR)/$(DYLIB_NAME)
BLACKLIST_SOURCE = lib$(PROJECT).dylib.blacklist
BLACKLIST_DEST = $(INSTALL_DIR)/lib$(PROJECT).dylib.blacklist
WHITELIST_SOURCE = lib$(PROJECT).dylib.whitelist
WHITELIST_DEST = $(INSTALL_DIR)/lib$(PROJECT).dylib.whitelist

# Dylib settings
DYLIB_FLAGS = -dynamiclib \
              -install_name @rpath/$(DYLIB_NAME) \
              -compatibility_version 1.0.0 \
              -current_version 1.0.0

# Help target - show usage information
help:
	@echo "macOS Blur Tweak Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  make          - Build the blur tweak dylib (default, runs clean first)"
	@echo "  make install  - Build and install the dylib to $(INSTALL_DIR)"
	@echo "  make test     - Install and restart Finder"
	@echo "  make clean    - Remove build directory and compiled objects"
	@echo "  make uninstall - Remove installed dylib and configuration files"
	@echo "  make help     - Show this help message"
	@echo ""
	@echo "Project: $(PROJECT)"
	@echo "Output: $(BUILD_DIR)/$(DYLIB_NAME)"
	@echo "Install path: $(INSTALL_PATH)"

# Default target
all: clean $(BUILD_DIR)/$(DYLIB_NAME)

# Create build directory
$(BUILD_DIR):
	@rm -rf $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/src
	@mkdir -p $(BUILD_DIR)/ZKSwizzle

# Compile blurtweak.m
$(BUILD_DIR)/src/blurtweak.o: $(SOURCE_DIR)/blurtweak.m | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(ARCHS) -c $< -o $@

# Compile ZKSwizzle.m from parent directory
$(BUILD_DIR)/ZKSwizzle/ZKSwizzle.o: $(REPO_ROOT)/ZKSwizzle/ZKSwizzle.m | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(ARCHS) -c $< -o $@

# Link dylib
$(BUILD_DIR)/$(DYLIB_NAME): $(DYLIB_OBJECTS)
	$(CC) $(DYLIB_FLAGS) $(ARCHS) $(DYLIB_OBJECTS) -o $@ \
	-F$(FRAMEWORK_PATH) \
	-F$(PRIVATE_FRAMEWORK_PATH) \
	$(PUBLIC_FRAMEWORKS) \
	-L$(SDKROOT)/usr/lib

# Install dylib
install: $(BUILD_DIR)/$(DYLIB_NAME)
	@echo "Installing blur tweak to $(INSTALL_DIR)"
	sudo mkdir -p $(INSTALL_DIR)
	sudo install -m 755 $(BUILD_DIR)/$(DYLIB_NAME) $(INSTALL_DIR)
	@if [ -f $(BLACKLIST_SOURCE) ]; then \
		sudo cp $(BLACKLIST_SOURCE) $(BLACKLIST_DEST); \
		sudo cp $(WHITELIST_SOURCE) $(WHITELIST_DEST); \
		sudo chmod 644 $(BLACKLIST_DEST); \
		echo "Installed $(DYLIB_NAME) and blacklist"; \
	else \
		echo "Installed $(DYLIB_NAME)"; \
	fi

# Test target
test: install
	@echo "Killing Finder completely..."
	@killall Finder 2>/dev/null || true
	@pkill -9 Finder 2>/dev/null || true
	@sleep 1
	@echo "Opening Finder twice..."
	@open -a Finder; open -a Finder

# Clean build files
clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned build directory"

# Uninstall
uninstall:
	@sudo rm -f $(INSTALL_PATH)
	@sudo rm -f $(BLACKLIST_DEST)
	@echo "Uninstalled $(DYLIB_NAME)"

.PHONY: all clean install test uninstall help
