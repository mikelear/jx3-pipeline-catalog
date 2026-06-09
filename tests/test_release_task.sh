#!/usr/bin/env bash
# Hermetic parse-assertion test for tasks/python/release.yaml.
#
# Asserts the structural invariants introduced 2026-06-09 to prevent
# phantom-pin promotions (memory: feedback_failed_release_must_not_propagate_pin):
#
#   1. Every multi-line script block in the task starts with `set -e`
#      (memory: feedback_pr_pytest_step_must_set_e).
#   2. A `verify-image-pullable` step exists and uses a crane image.
#   3. `verify-image-pullable` is declared BEFORE every promote-* step
#      in the steps list. In Tekton, steps within a task run sequentially
#      and a failing step halts the task — so step ordering IS the
#      dependency. There is no step-level `runAfter` in Tekton.
#
# Catalog repo PR gates are thin (memory: feedback_dockerfiles_repo_no_pr_gates),
# so this test is the pre-merge structural smoke test. Run it locally
# before pushing changes to tasks/python/release.yaml.
#
# Requires: yq (v4+) OR python3 with PyYAML. The script auto-detects.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${REPO_ROOT}/tasks/python/release.yaml"

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET not found"
  exit 1
fi

# Prefer python3+PyYAML — more deterministic than yq across versions.
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  PARSER=python
elif command -v yq >/dev/null 2>&1; then
  PARSER=yq
else
  echo "FAIL: neither python3+PyYAML nor yq is available — cannot parse YAML"
  exit 1
fi

echo "parser: $PARSER"
echo "target: $TARGET"
echo

if [ "$PARSER" = "python" ]; then
  python3 - "$TARGET" <<'PYEOF'
import sys
import yaml

target = sys.argv[1]
with open(target) as f:
    doc = yaml.safe_load(f)

steps = doc["spec"]["pipelineSpec"]["tasks"][0]["taskSpec"]["steps"]
step_names = [s.get("name", "") for s in steps]
failures = []

# --- Invariant 1: every script block starts with `set -e` -----------------
for s in steps:
    script = s.get("script")
    if not script:
        continue  # e.g. check-registry has no script
    # Drop the shebang line, then look at the first non-comment, non-blank line.
    lines = script.splitlines()
    if lines and lines[0].startswith("#!"):
        lines = lines[1:]
    first_executable = None
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        first_executable = stripped
        break
    if first_executable != "set -e":
        failures.append(
            f"step '{s['name']}': first executable line is "
            f"{first_executable!r}, expected 'set -e'"
        )

# --- Invariant 2: verify-image-pullable exists with crane image -----------
verify_idx = None
for i, s in enumerate(steps):
    if s.get("name") == "verify-image-pullable":
        verify_idx = i
        if "crane" not in s.get("image", ""):
            failures.append(
                f"verify-image-pullable: image {s.get('image')!r} "
                "must be a crane image"
            )
        break
if verify_idx is None:
    failures.append("verify-image-pullable step is missing")

# --- Invariant 3: verify-image-pullable precedes every promote-* step -----
if verify_idx is not None:
    for i, s in enumerate(steps):
        name = s.get("name", "")
        if name.startswith("promote-") and i < verify_idx:
            failures.append(
                f"step '{name}' (index {i}) appears BEFORE "
                f"verify-image-pullable (index {verify_idx}); promote-* "
                "must run after the phantom-pin gate"
            )

# --- Invariant 4: verify-image-pullable runs AFTER build-container-build --
# (so we're checking an image that kaniko just pushed)
if verify_idx is not None:
    try:
        build_idx = step_names.index("build-container-build")
        if build_idx >= verify_idx:
            failures.append(
                f"build-container-build (index {build_idx}) must precede "
                f"verify-image-pullable (index {verify_idx})"
            )
    except ValueError:
        failures.append("build-container-build step is missing")

# --- Report ---------------------------------------------------------------
print(f"steps in order: {step_names}")
print()
if failures:
    print(f"FAIL: {len(failures)} invariant violation(s):")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("PASS: all invariants hold")
PYEOF
else
  # yq fallback. Less precise (treats script blocks as opaque strings) but
  # catches the structural invariants. Requires yq v4.
  set -e
  echo "checking step names + ordering..."
  STEP_NAMES="$(yq '.spec.pipelineSpec.tasks[0].taskSpec.steps[].name // "" | select(. != "")' "$TARGET")"
  echo "$STEP_NAMES"
  echo
  echo "$STEP_NAMES" | grep -qx "verify-image-pullable" || {
    echo "FAIL: verify-image-pullable step missing"; exit 1; }

  VERIFY_LINE=$(echo "$STEP_NAMES" | grep -nx "verify-image-pullable" | cut -d: -f1)
  for promote in promote-changelog promote-helm-release promote-jx-promote; do
    PROMOTE_LINE=$(echo "$STEP_NAMES" | grep -nx "$promote" | cut -d: -f1 || true)
    if [ -n "$PROMOTE_LINE" ] && [ "$PROMOTE_LINE" -lt "$VERIFY_LINE" ]; then
      echo "FAIL: $promote precedes verify-image-pullable"; exit 1;
    fi
  done

  echo "checking every script block contains 'set -e'..."
  NUM_SCRIPTS=$(yq '.spec.pipelineSpec.tasks[0].taskSpec.steps[] | select(has("script")) | .name' "$TARGET" | wc -l)
  NUM_WITH_SET_E=$(yq '.spec.pipelineSpec.tasks[0].taskSpec.steps[] | select(has("script")) | select(.script | test("\\bset -e\\b")) | .name' "$TARGET" | wc -l)
  if [ "$NUM_SCRIPTS" != "$NUM_WITH_SET_E" ]; then
    echo "FAIL: $NUM_WITH_SET_E of $NUM_SCRIPTS script blocks contain 'set -e'"; exit 1;
  fi
  echo "PASS: $NUM_SCRIPTS/$NUM_SCRIPTS script blocks contain 'set -e'"
fi
