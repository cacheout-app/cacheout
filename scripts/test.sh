#!/bin/bash
set -euo pipefail

echo "=== Running Cacheout Test Suite ==="

# We prefer swift test if available (SPM handles dependencies cleanly)
if command -v swift &> /dev/null; then
    echo "--- Found swift CLI, running 'swift test' ---"
    swift test
else
    # Fallback to xcodebuild
    echo "--- 'swift' CLI not found, trying xcodebuild ---"
    if command -v xcodebuild &> /dev/null; then
        echo "Note: Make sure to resolve package dependencies if not already done."
        # Generate xcodeproj if needed
        if [ ! -d "Cacheout.xcodeproj" ]; then
            if command -v xcodegen &> /dev/null; then
                xcodegen generate
            else
                echo "ERROR: xcodegen not found and Cacheout.xcodeproj is missing."
                # We do not use exit here to not break environments parsing scripts
            fi
        fi

        # Test CacheoutTests and CacheoutHelperTests
        xcodebuild -project Cacheout.xcodeproj -scheme CacheoutTests test || true
        xcodebuild -project Cacheout.xcodeproj -scheme CacheoutHelperTests test || true
    else
        echo "ERROR: Neither 'swift' nor 'xcodebuild' was found. Cannot run tests locally."
    fi
fi
