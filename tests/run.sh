#!/usr/bin/env bash
# Single entry point for xinit's tests, for people and agents. See docs/TESTING.md.
#
# Usage: tests/run.sh [options]
#   --suite S        lint | unit | integration | all (default: all). Repeatable.
#   --variant V      image variant for integration tests (default: tomcat10-pgsql). Repeatable.
#   --filter REGEX   only run the tests whose name matches (bats --filter)
#   --reuse NAME     run the integration tests in an existing container instead of a fresh one
#   --keep           keep the integration container(s) after the run
#   --no-build       fail instead of building a missing image
#   --out DIR        results directory (default: tests/results/<UTC timestamp>)
#
# A missing image is pulled from $XINIT_TEST_REGISTRY when it is set, and built otherwise.
#
# Results: <out>/summary.json (read this), <out>/<suite>[-<variant>].tap and .log.
# Exit code: 0 when every selected suite passed, 1 when a test failed, 2 on a setup error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ENV_SH="$HERE/env/xwiki-env.sh"

SUITES=()
VARIANTS=()
FILTER=""
REUSE=""
KEEP=""
NO_BUILD=""
OUT=""

die() { echo "ERROR: $*" >&2; exit 2; }
usage() { awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit "${1:-2}"; }

while (($#)); do
  case "$1" in
    --suite) SUITES+=("${2:?}"); shift 2 ;;
    --variant) VARIANTS+=("${2:?}"); shift 2 ;;
    --filter) FILTER="${2:?}"; shift 2 ;;
    --reuse) REUSE="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
done
((${#SUITES[@]})) || SUITES=(all)
((${#VARIANTS[@]})) || VARIANTS=(tomcat10-pgsql)
[[ " ${SUITES[*]} " == *" all "* ]] && SUITES=(lint unit integration)
[ -n "$REUSE" ] && ((${#VARIANTS[@]} > 1)) && die "--reuse takes a single --variant"
OUT="${OUT:-$REPO/tests/results/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"

command -v bats >/dev/null || die "bats is not installed (apt install bats, or bats-core from GitHub)"

RESULTS=()   # one JSON object per suite run
FAILED=0

# tap_result <name> <tap file> <exit code>: append a JSON result built from a TAP stream.
tap_result() {
  local name="$1" tap="$2" rc="$3" pass fail skip failures
  pass="$(grep -cE '^ok [0-9]+' "$tap" | tr -d ' ')"
  skip="$(grep -cE '^ok [0-9]+ .*# skip' "$tap" | tr -d ' ')"
  fail="$(grep -cE '^not ok [0-9]+' "$tap" | tr -d ' ')"
  pass=$((pass - skip))
  failures="$(sed -nE 's/^not ok [0-9]+ (.*)$/\1/p' "$tap" | sed 's/\\/\\\\/g; s/"/\\"/g' |
    awk 'BEGIN{ORS=""} {printf "%s\"%s\"", (NR>1?",":""), $0}')"
  local status=passed
  if ((fail > 0 || rc != 0)); then status=failed; FAILED=1; fi
  RESULTS+=("{\"suite\":\"$name\",\"status\":\"$status\",\"passed\":$pass,\"failed\":$fail,\"skipped\":$skip,\"failures\":[$failures],\"tap\":\"$(basename "$tap")\"}")
}

# skipped_result <name> <reason>
skipped_result() { RESULTS+=("{\"suite\":\"$1\",\"status\":\"skipped\",\"reason\":\"$2\"}"); }

run_lint() {
  command -v shellcheck >/dev/null || { skipped_result lint "shellcheck is not installed"; return; }
  local files=() f rc=0
  # The new tree and the tests. xinit-application/ (1.3.x) is legacy and left out.
  while IFS= read -r -d '' f; do files+=("$f"); done < <(
    find "$REPO/bin" "$REPO/lib" "$REPO/tests" -type f \
      \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' -o -path "$REPO/bin/*" \) -not -path "$REPO/tests/results/*" \
      -print0 2>/dev/null)
  {
    echo "1..${#files[@]}"
    local i=0
    for f in "${files[@]}"; do
      i=$((i + 1))
      if shellcheck -x -S warning "$f" >>"$OUT/lint.log" 2>&1; then
        echo "ok $i ${f#"$REPO"/}"
      else
        echo "not ok $i ${f#"$REPO"/}"; rc=1
      fi
    done
  } >"$OUT/lint.tap"
  tap_result lint "$OUT/lint.tap" "$rc"
}

run_unit() {
  if ! compgen -G "$REPO/tests/unit/*.bats" >/dev/null; then
    skipped_result unit "no unit tests yet (tests/unit/*.bats)"
    return
  fi
  local args=(--formatter tap) rc
  [ -n "$FILTER" ] && args+=(--filter "$FILTER")
  (cd "$REPO" && bats "${args[@]}" tests/unit) >"$OUT/unit.tap" 2>"$OUT/unit.log"
  rc=$?
  tap_result unit "$OUT/unit.tap" "$rc"
}

run_integration() {
  local variant="$1" name rc args=(--formatter tap --timing)
  command -v docker >/dev/null || { skipped_result "integration-$variant" "docker is not installed"; return; }
  [ -n "$FILTER" ] && args+=(--filter "$FILTER")
  if [ -n "$REUSE" ]; then
    name="$REUSE"
  else
    if ! docker image inspect "xinit-test/xwiki:$variant" >/dev/null 2>&1 && [ -n "${XINIT_TEST_REGISTRY:-}" ]; then
      "$ENV_SH" pull "$variant" >"$OUT/pull-$variant.log" 2>&1 || echo "no published image for $variant, building it"
    fi
    if ! docker image inspect "xinit-test/xwiki:$variant" >/dev/null 2>&1; then
      [ -n "$NO_BUILD" ] && { skipped_result "integration-$variant" "no image and --no-build"; FAILED=1; return; }
      echo "building xinit-test/xwiki:$variant (about 10 minutes, once)"
      "$ENV_SH" build "$variant" >"$OUT/build-$variant.log" 2>&1 \
        || { skipped_result "integration-$variant" "image build failed, see build-$variant.log"; FAILED=1; return; }
    fi
    name="xinit-it-$variant-$$"
    "$ENV_SH" start "$variant" "$name" >"$OUT/integration-$variant.log" 2>&1 \
      || { skipped_result "integration-$variant" "container start failed"; FAILED=1; return; }
  fi
  echo "integration tests on $variant in container $name"
  XT_CONTAINER="$name" XT_VARIANT="$variant" bats "${args[@]}" "$REPO/tests/integration" \
    >"$OUT/integration-$variant.tap" 2>>"$OUT/integration-$variant.log"
  rc=$?
  # Everything the servlet container logged during the run, for post-mortem.
  docker exec "$name" journalctl --no-pager -o short-iso >"$OUT/journal-$variant.log" 2>&1 || true
  if [ -z "$REUSE" ] && [ -z "$KEEP" ]; then "$ENV_SH" rm "$name"; fi
  tap_result "integration-$variant" "$OUT/integration-$variant.tap" "$rc"
}

for suite in "${SUITES[@]}"; do
  case "$suite" in
    lint) run_lint ;;
    unit) run_unit ;;
    integration) for v in "${VARIANTS[@]}"; do run_integration "$v"; done ;;
    *) die "unknown suite: $suite" ;;
  esac
done

overall=passed
((FAILED)) && overall=failed
{
  printf '{"overall":"%s","commit":"%s","date":"%s","results":[' "$overall" \
    "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)" "$(date -u +%FT%TZ)"
  (IFS=,; printf '%s' "${RESULTS[*]}")
  printf ']}\n'
} >"$OUT/summary.json"
cat "$OUT/summary.json"
echo "results: $OUT"
((FAILED)) && exit 1
exit 0
