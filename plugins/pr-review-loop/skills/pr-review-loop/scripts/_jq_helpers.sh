#!/bin/bash
# Shared jq helper functions for PR review scripts

# Priority detection function for various code review bot formats
# Supports: Gemini, Cursor, Claude, and general markdown priority markers
# shellcheck disable=SC2089
PRIORITY_DETECT='
    def detect_priority:
        # Gemini format: ![critical], ![high], ![medium], ![low]
        if test("!\\[critical\\]"; "i") then "critical"
        elif test("!\\[high\\]"; "i") then "high"
        elif test("!\\[medium\\]"; "i") then "medium"
        elif test("!\\[low\\]"; "i") then "low"
        # Cursor format: <!-- **High Severity** -->
        elif test("Critical Severity"; "i") then "critical"
        elif test("High Severity"; "i") then "high"
        elif test("Medium Severity"; "i") then "medium"
        elif test("Low Severity"; "i") then "low"
        # Claude/general markdown: **Critical**, ### Critical, CRITICAL:
        elif test("\\*\\*Critical|### Critical|CRITICAL:"; "i") then "critical"
        elif test("\\*\\*High|### High|HIGH:"; "i") then "high"
        elif test("\\*\\*Medium|### Medium|MEDIUM:"; "i") then "medium"
        elif test("\\*\\*Low|### Low|LOW:"; "i") then "low"
        # Cursor Bug headers
        elif test("### Bug:"; "i") then "high"
        elif test("### Issue:"; "i") then "medium"
        elif test("### Suggestion:"; "i") then "low"
        else "unknown"
        end;
'

# shellcheck disable=SC2090
export PRIORITY_DETECT
