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
    -I$(REPO_ROOT)/ZKSwizzle

ARCHS = -arch x86_64 -arch arm64 -arch arm64e
FRAMEWORK_PATH = $(SDKROOT)/System/Library/Frameworks
PRIVATE_FRAMEWORK_PATH = $(SDKROOT)/System/Library/PrivateFrameworks
PUBLIC_FRAMEWORKS = -framework Foundation -framework AppKit -framework QuartzCore \
    -framework Cocoa -framework CoreFoundation

# Project settings
PROJECT = blur_tweak
DYLIB_NAME = lib$(PROJECT).dylib
CLI_NAME = blurctl
BUILD_DIR = build
SOURCE_DIR = src
INSTALL_DIR = /var/ammonia/core/tweaks
CLI_INSTALL_DIR = /usr/local/bin

# Source files
DYLIB_SOURCES = $(SOURCE_DIR)/blurtweak.m $(REPO_ROOT)/ZKSwizzle/ZKSwizzle.m
DYLIB_OBJECTS = $(BUILD_DIR)/src/blurtweak.o $(BUILD_DIR)/ZKSwizzle/ZKSwizzle.o

# CLI tool
CLI_SOURCE = $(SOURCE_DIR)/blurctl.m
CLI_OBJECT = $(BUILD_DIR)/blurctl.o

# Installation paths
INSTALL_PATH = $(INSTALL_DIR)/$(DYLIB_NAME)
CLI_INSTALL_PATH = $(CLI_INSTALL_DIR)/$(CLI_NAME)
BLACKLIST_SOURCE = lib$(PROJECT).dylib.blacklist
BLACKLIST_DEST = $(INSTALL_DIR)/lib$(PROJECT).dylib.blacklist

# Dylib settings
DYLIB_FLAGS = -dynamiclib \
              -install_name @rpath/$(DYLIB_NAME) \
              -compatibility_version 1.0.0 \
              -current_version 1.0.0

# Default target
all: clean $(BUILD_DIR)/$(DYLIB_NAME) $(BUILD_DIR)/$(CLI_NAME)

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

# Build CLI tool
$(BUILD_DIR)/$(CLI_NAME): $(CLI_SOURCE)
	@rm -f $(BUILD_DIR)/$(CLI_NAME)
	$(CC) $(CFLAGS) $(ARCHS) $(CLI_SOURCE) \
		-framework Foundation \
		-framework CoreFoundation \
		-o $@

# Install both dylib and CLI tool
install: $(BUILD_DIR)/$(DYLIB_NAME) $(BUILD_DIR)/$(CLI_NAME)
	@echo "Installing blur tweak to $(INSTALL_DIR) and CLI to $(CLI_INSTALL_DIR)"
	sudo mkdir -p $(INSTALL_DIR)
	sudo mkdir -p $(CLI_INSTALL_DIR)
	sudo install -m 755 $(BUILD_DIR)/$(DYLIB_NAME) $(INSTALL_DIR)
	sudo install -m 755 $(BUILD_DIR)/$(CLI_NAME) $(CLI_INSTALL_DIR)
	@if [ -f $(BLACKLIST_SOURCE) ]; then \
		sudo cp $(BLACKLIST_SOURCE) $(BLACKLIST_DEST); \
		sudo chmod 644 $(BLACKLIST_DEST); \
		echo "Installed $(DYLIB_NAME), $(CLI_NAME), and blacklist"; \
	else \
		echo "Installed $(DYLIB_NAME) and $(CLI_NAME)"; \
	fi

# Test target
test: install
	@echo "Restarting test applications..."
	$(eval TEST_APPS := Finder Safari Notes "System Settings" Calculator TextEdit)
	@for app in $(TEST_APPS); do \
		pkill -9 "$$app" 2>/dev/null || true; \
	done
	@sleep 1
	@echo "Relaunching test applications..."
	@for app in $(TEST_APPS); do \
		open -a "$$app" 2>/dev/null || true; \
	done
	@echo "Test applications restarted with blur tweak"

# Clean build files
clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned build directory"

# Uninstall
uninstall:
	@sudo rm -f $(INSTALL_PATH)
	@sudo rm -f $(CLI_INSTALL_PATH)
	@sudo rm -f $(BLACKLIST_DEST)
	@echo "Uninstalled $(DYLIB_NAME) and $(CLI_NAME)"

# Delete and restart apps
delete:
	@echo "Removing blur tweak and restarting apps..."
	$(eval TEST_APPS := Finder Safari Notes "System Settings" Calculator TextEdit)
	@for app in $(TEST_APPS); do \
		pkill -9 "$$app" 2>/dev/null || true; \
	done
	@sudo rm -f $(INSTALL_PATH)
	@sudo rm -f $(CLI_INSTALL_PATH)
	@sudo rm -f $(BLACKLIST_DEST)
	@sleep 1
	@open -a "Finder" || true
	@echo "Blur tweak removed and apps restarted"

.PHONY: all clean install test uninstall delete
