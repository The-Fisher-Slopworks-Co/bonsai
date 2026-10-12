# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The Fisher Slopworks Co

set shell := ["bash", "-euo", "pipefail", "-c"]

app := "Bonsai.app"
destination := "/Applications"

default:
    @just --list

# Build the app into build.noindex/<configuration>
build configuration="Debug":
    xcodegen generate
    xcodebuild -scheme Bonsai -configuration {{ configuration }} build | tail -40

# Build a Release and copy it to /Applications, replacing a running copy
install: (build "Release")
    if pgrep -xq Bonsai; then osascript -e 'quit app "Bonsai"'; fi
    rm -rf "{{ destination }}/{{ app }}"
    ditto "build.noindex/Release/{{ app }}" "{{ destination }}/{{ app }}"
    @echo "Installed {{ destination }}/{{ app }}"
