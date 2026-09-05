#!/usr/bin/env bash
#
# coverage-gate.sh — compute line coverage from a `swift test --enable-code-coverage`
# run and fail if it dropped below a floor.
#
# Usage:
#   scripts/coverage-gate.sh [MIN_LINE_COVERAGE]
#
# The floor is taken from (in order): $1, $MIN_LINE_COVERAGE, then a built-in default.
# Set $GITHUB_STEP_SUMMARY (CI does this automatically) to also get a Markdown summary.
#
# Prerequisites: run `swift test --enable-code-coverage --no-parallel` first so the
# profdata + instrumented test binaries exist under .build/.

set -euo pipefail

MIN_LINE_COVERAGE="${1:-${MIN_LINE_COVERAGE:-85}}"
# Product code only: exclude the build dir, tests, SwiftPM checkouts.
IGNORE_REGEX='\.build|Tests/|checkouts/'

profdata="$(find .build -name 'default.profdata' -path '*codecov*' 2>/dev/null | head -1)"
if [[ -z "${profdata}" ]]; then
    echo "::error::No coverage profdata found. Run 'swift test --enable-code-coverage --no-parallel' first." >&2
    exit 1
fi

objects=()
while IFS= read -r bundle; do
    name="$(basename "${bundle}" .xctest)"
    binary="${bundle}/Contents/MacOS/${name}"
    [[ -f "${binary}" ]] || binary="${bundle}/${name}"  # Linux layout
    [[ -f "${binary}" ]] && objects+=(-object "${binary}")
done < <(find .build -name '*.xctest' 2>/dev/null)

if [[ ${#objects[@]} -eq 0 ]]; then
    echo "::error::No instrumented .xctest binaries found under .build." >&2
    exit 1
fi

llvm_cov() { xcrun llvm-cov "$@" 2>/dev/null || llvm-cov "$@"; }

# Human-readable table (goes to the CI log).
report="$(llvm_cov report "${objects[@]}" -instr-profile "${profdata}" -ignore-filename-regex="${IGNORE_REGEX}")"
echo "${report}"

# Machine-readable totals.
summary_file="$(mktemp)"
trap 'rm -f "${summary_file}"' EXIT
llvm_cov export "${objects[@]}" -instr-profile "${profdata}" \
    -ignore-filename-regex="${IGNORE_REGEX}" -summary-only > "${summary_file}"

read -r line_pct region_pct < <(python3 - "${summary_file}" <<'PY'
import json, sys

with open(sys.argv[1]) as handle:
    totals = json.load(handle)["data"][0]["totals"]

print(f"{totals['lines']['percent']:.2f} {totals['regions']['percent']:.2f}")
PY
)

echo
echo "Line coverage:   ${line_pct}%  (floor: ${MIN_LINE_COVERAGE}%)"
echo "Region coverage: ${region_pct}%"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### Test coverage"
        echo
        echo "| Metric | Coverage | Floor |"
        echo "| --- | --- | --- |"
        echo "| Line | ${line_pct}% | ${MIN_LINE_COVERAGE}% |"
        echo "| Region | ${region_pct}% | — |"
        echo
        echo '<details><summary>Per-file report</summary>'
        echo
        echo '```'
        echo "${report}"
        echo '```'
        echo
        echo '</details>'
    } >> "${GITHUB_STEP_SUMMARY}"
fi

if ! awk -v have="${line_pct}" -v want="${MIN_LINE_COVERAGE}" 'BEGIN { exit !(have + 1e-9 >= want) }'; then
    echo "::error::Line coverage ${line_pct}% is below the ${MIN_LINE_COVERAGE}% floor." >&2
    exit 1
fi

echo "Coverage gate passed."
