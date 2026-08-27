# JustSpeak - Ultra-Low-Latency Push-to-Talk macOS Voice Dictation
# Makefile Automation

RUNNER = ./justspeak

.PHONY: all run start check-permissions test-api test-audio setup install clean check lint format help

all: run

## run: Start the JustSpeak voice dictation tool (pure Apple-signed Swift runtime)
run: setup
	@$(RUNNER)

## start: Alias for make run
start: run

## check-permissions: Check macOS Accessibility, Microphone, and Input Monitoring permissions
check-permissions:
	@$(RUNNER) --check-permissions

## test-api: Verify Gemini API key, endpoint reachability, and response latency
test-api: setup
	@$(RUNNER) --test-api

## test-audio: Record a 3-second audio sample from the microphone and transcribe via Gemini
test-audio: setup
	@$(RUNNER) --test-audio

## setup: Initialize local .env configuration from .env.example
setup:
	@if [ ! -f .env ]; then \
		echo "Creating .env from .env.example..."; \
		cp .env.example .env; \
	fi

## install: Alias for make setup
install: setup

## check: Run system permission diagnostics and API connectivity check
check: check-permissions test-api

# swift-format ships inside the Apple toolchain (Xcode 16+ / matching CLT) as a
# `swift format` subcommand - Apple-signed, so Santa-safe. SwiftLint is a third-party
# compiled binary and is NOT usable in this environment.
## lint: Lint src/*.swift with Apple's swift-format (Xcode 16+; read-only)
lint:
	@swift format lint --strict --recursive src

## format: Rewrite src/*.swift in place with Apple's swift-format (Xcode 16+)
format:
	@swift format --in-place --recursive src

## clean: Remove temporary files and caches
clean:
	@rm -rf .DS_Store .build
	@echo "Cleaned working directory."

## help: Show this help summary
help:
	@echo "JustSpeak Makefile targets:"
	@echo ""
	@grep -E '^## ' $(MAKEFILE_LIST) | sed -e 's/## //' | awk 'BEGIN {FS = ":"}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
