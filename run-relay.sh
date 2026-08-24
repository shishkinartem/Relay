#!/bin/sh
# Runs the built app in the foreground with its log on stdout.
exec ./build/macos/Build/Products/Debug/relay.app/Contents/MacOS/relay 2>&1 | tee /tmp/relay.log
