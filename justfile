# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 The Fisher Slopworks Co

set shell := ["bash", "-euo", "pipefail", "-c"]

app := "Bonsai.app"
destination := "/Applications"
# The first Apple Development identity in the keychain; ad hoc signing without one.
# A stable signature keeps macOS privacy grants (Documents and others) across rebuilds.
identity := `security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }'`

default:
    @just --list

# Build the app into build.noindex/<configuration>
build configuration="Debug":
    xcodegen generate
    xcodebuild -scheme Bonsai -configuration {{ configuration }} build {{ if identity == "" { "" } else { "CODE_SIGN_IDENTITY='" + identity + "'" } }} | tail -40

# Build a Release and copy it to /Applications, replacing a running copy
install: (build "Release")
    if pgrep -xq Bonsai; then osascript -e 'quit app "Bonsai"'; fi
    rm -rf "{{ destination }}/{{ app }}"
    ditto "build.noindex/Release/{{ app }}" "{{ destination }}/{{ app }}"
    @echo "Installed {{ destination }}/{{ app }}"
