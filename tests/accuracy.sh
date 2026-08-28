#!/bin/sh
# Accuracy gate: score the indexer against the hand-verified golden corpora in
# tests/golden/ and fail when any language drops below its recorded floor.
#
# The floors are a ratchet: they start at the measured baseline, so this gate
# only ever catches a regression. A wave that improves a language re-records
# them with `zig build bench -- --update-floors`, which raises that language's
# floor and locks the gain in.
set -eu

bin=$1
repo=$2
shift 2

"$bin" "$repo" "$@"
