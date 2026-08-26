# JustSpeak - Ultra-Low-Latency Push-to-Talk macOS Voice Dictation
# Makefile Automation

SWIFT ?= /usr/bin/swift
SCRIPT = justspeak.swift

.PHONY: all run start check-permissions test-api test-audio setup install clean check help

all: run

## run: Start the JustSpeak voice dictation tool (pure Apple-signed Swift runtime)
run: setup
	@$(SWIFT) $(SCRIPT)

## start: Alias for make run
start: run

## check-permissions: Check macOS Accessibility, Microphone, and Input Monitoring permissions
check-permissions:
	@$(SWIFT) $(SCRIPT) --check-permissions

## test-api: Verify Gemini API key, endpoint reachability, and response latency
test-api: setup
	@$(SWIFT) $(SCRIPT) --test-api

## test-audio: Record a 3-second audio sample from the microphone and transcribe via Gemini
test-audio: setup
	@$(SWIFT) $(SCRIPT) --test-audio

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

## clean: Remove temporary files and caches
clean:
	@rm -rf .DS_Store
	@echo "Cleaned working directory."

## help: Show this help summary
help:
	@echo "JustSpeak Makefile targets:"
	@echo ""
	@grep -E '^## ' $(MAKEFILE_LIST) | sed -e 's/## //' | awk 'BEGIN {FS = ":"}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
