#!/usr/bin/swift
//
//  JustSpeak (generated from src/*.swift by the ./justspeak runner)
//  JustSpeak - Ultra-Low-Latency Push-to-Talk macOS Voice Dictation
//
//  Zero native compiled dependencies. Pure Apple Swift.
//  Uses AVFoundation, CoreGraphics CGEvent, and Gemini Live WebSockets / REST.
//

import Foundation
import AVFoundation
import AppKit
import CoreGraphics
import CoreAudio
import AudioToolbox
import ApplicationServices
import Darwin
import Network
import SQLite3
import Carbon
import IOKit

// Unbuffer standard output so terminal output flushes immediately in compiled binary
setbuf(stdout, nil)
setbuf(stderr, nil)

atexit { Logger.flush() }
