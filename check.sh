#!/usr/bin/env bash
# Fail a pull request whose commits call for a release (Conventional Commits)
# when the project version didn't increase compared with the base commit.
# Inputs arrive as environment variables (see action.yml and README.md).
set -euo pipefail

# ERE checked against every line of each commit message in regex mode,
# mirroring the cz_conventional_commits bump rules.
DEFAULT_BUMP_PATTERN='^(feat|fix|refactor|perf)(\(.+\))?!?:|^[[:alnum:]_]+(\(.+\))?!:|^BREAKING[- ]CHANGE:'
DEFAULT_COMMITIZEN_VERSION=4.20.1

BASE_SHA=${BASE_SHA:-}
HEAD_SHA=${HEAD_SHA:-}
VERSION_FILE=${VERSION_FILE:-}
VERSION_PATTERN=${VERSION_PATTERN:-}
BUMP_PATTERN=${BUMP_PATTERN:-$DEFAULT_BUMP_PATTERN}
COMMITIZEN_VERSION=${COMMITIZEN_VERSION:-$DEFAULT_COMMITIZEN_VERSION}
ENFORCE_INCREMENT=${ENFORCE_INCREMENT:-true}
CHECK_CONSISTENCY=${CHECK_CONSISTENCY:-true}
CHECK_COMMITS=${CHECK_COMMITS:-false}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
OUTPUT=${GITHUB_OUTPUT:-/dev/null}
HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cz_helper.py"

# The PR's checkout may hold uv.toml/pyproject.toml settings; don't let them
# choose the package index or Python used to run Commitizen.
export UV_NO_CONFIG=1 UV_NO_PROGRESS=1 GIT_LFS_SKIP_SMUDGE=1 PYTHONDONTWRITEBYTECODE=1

details=()
detail() { details+=("- $1"); }

# Escape data for a workflow command so it can't start a new command.
escape() {
  local s=${1//'%'/'%25'}
  s=${s//$'\r'/'%0D'}
  printf '%s' "${s//$'\n'/'%0A'}"
}

output() { printf '%s=%s\n' "$1" "$2" >>"$OUTPUT"; }

pass() {
  echo "✅ $1"
  printf '%s\n' "### ✅ $1" "" "${details[@]}" >>"$SUMMARY"
  exit 0
}

# fail MESSAGE [LOG]: LOG (e.g. command output) is added to the log and summary.
fail() {
  echo "::error title=Version bump check::$(escape "$1")"
  printf '%s\n' "### ❌ $1" "" "${details[@]}" >>"$SUMMARY"
  if [[ -n ${2:-} ]]; then
    local token
    token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    # LOG may contain commit messages; stop them from acting as workflow commands.
    printf '::stop-commands::%s\n%s\n::%s::\n' "$token" "$2" "$token"
    printf '\n%s\n%s\n%s\n' '```text' "$2" '```' >>"$SUMMARY"
  fi
  exit 1
}

require_bool() {
  [[ $2 == true || $2 == false ]] || fail "Input $1 must be 'true' or 'false', got '$2'"
}

cz() { uvx --quiet --from "commitizen==$COMMITIZEN_VERSION" cz "$@"; }
cz_helper() { uvx --quiet --from "commitizen==$COMMITIZEN_VERSION" python "$HELPER" "$@"; }

# capture WHAT COMMAND...: run COMMAND and store its single-line stdout in $out.
# cz reports some errors (e.g. a missing version) on stderr with exit status 0.
capture() {
  local what=$1 err
  shift
  err=$(mktemp)
  if ! out=$("$@" 2>"$err") || [[ -z $out || $out == *$'\n'* ]]; then
    fail "$what failed" "$(cat "$err")${out:+$'\n'$out}"
  fi
  rm -f "$err"
}

check_commit_messages() {
  [[ $CHECK_COMMITS == true ]] || return 0
  local log
  if ! log=$(cz check --rev-range "$BASE_SHA..$HEAD_SHA" 2>&1); then
    fail "Commit messages don't follow the commit rules" "$log"
  fi
  detail "Commit messages: valid"
}

# --- verdict -----------------------------------------------------------------
# Each mode finds out whether the unreleased commits require a bump, reads the
# base and head versions, and compares them. Only these functions decide whether
# the bump passes (see docs/adr/0001-bumps-follow-cz-bump.md).

# no_base_version REQUIRED WHY: the base commit has no version, for reason WHY.
# There's nothing to keep, so it passes unless the unreleased commits require a bump.
no_base_version() {
  [[ $1 == true ]] || pass "No unreleased commits require a version bump"
  fail "$2"
}

# verdict REQUIRED BASE HEAD RELATION [NEED]: pass or fail the bump from BASE to HEAD.
# RELATION is how HEAD compares with BASE (`cz_helper.py compare` explains the words):
# unchanged, decreased, too-small, finalization or increased. NEED says what the
# unreleased commits require (e.g. "a MINOR bump to 1.3.0").
verdict() {
  local required=$1 base=$2 head=$3 relation=$4 need=${5:+; the unreleased commits require $5}
  if [[ $required == false ]]; then
    case $relation in
    unchanged) pass "No unreleased commits require a version bump" ;;
    finalization) pass "Version finalized ($base → $head)" ;;
    *) fail "Version must not change when no unreleased commits require a bump (base: $base, head: $head)" ;;
    esac
  fi
  case $relation in
  increased | finalization) pass "Version increased ($base → $head)" ;;
  unchanged | decreased) fail "Version must increase (base: $base, head: $head)$need" ;;
  too-small) fail "Version $head is too small$need (base: $base)" ;;
  *) fail "Unexpected comparison result: $relation" ;;
  esac
}

# --- regex mode --------------------------------------------------------------

# regex_version LABEL SHA: store the version in VERSION_FILE at commit SHA in $out.
regex_version() {
  git cat-file -e "$2:$VERSION_FILE" 2>/dev/null ||
    fail "$VERSION_FILE doesn't exist in the $1 commit (${2:0:7})"
  out=$(git show "$2:$VERSION_FILE" | grep -Po -- "$VERSION_PATTERN" || true)
  [[ -n $out && $out != *$'\n'* ]] ||
    fail "Expected exactly one version-pattern match in $VERSION_FILE at $1 (${2:0:7})"
}

# regex_relation BASE HEAD: print how HEAD compares with BASE, in the words `verdict`
# takes (never too-small: regex mode has no expected version). Unchanged means the
# same text. A HEAD that differs from BASE only in `+build` metadata, which
# `version_gt` ignores, isn't an increase, so it counts as decreased.
regex_relation() {
  local base=${1%%+*}
  if [[ $2 == "$1" ]]; then
    echo unchanged
  elif ! version_gt "$2" "$1"; then
    echo decreased
  elif [[ $base == *-* && $2 == "${base%%-*}" ]]; then
    echo finalization
  else
    echo increased
  fi
}

# version_gt A B: A > B, using `sort -V` for the version core and semver rules
# for `-prerelease` suffixes (1.3.0 > 1.3.0-rc1); `+build` metadata is ignored.
version_gt() {
  local a=${1%%+*} b=${2%%+*}
  local ra=${a%%-*} rb=${b%%-*}
  local pa=${a#"$ra"} pb=${b#"$rb"}
  newest() { printf '%s\n' "$1" "$2" | sort -V | tail -n 1; }
  if [[ $ra != "$rb" ]]; then
    [[ $(newest "$ra" "$rb") == "$ra" ]]
  elif [[ -z $pa || -z $pb ]]; then
    [[ -z $pa && -n $pb ]]
  else
    [[ $pa != "$pb" && $(newest "$pa" "$pb") == "$pa" ]]
  fi
}

regex_mode() {
  [[ -n $VERSION_PATTERN ]] || fail "Input version-pattern is required when version-file is set"
  detail "Version file: \`$VERSION_FILE\`"
  check_commit_messages

  local messages status=0 required=true
  messages=$(git log --format=%B "$BASE_SHA..$HEAD_SHA")
  # A here-string instead of a pipe: `grep -q` exits on the first match, and
  # with pipefail the writer's SIGPIPE would turn a match into "no match".
  grep -Eq -- "$BUMP_PATTERN" <<<"$messages" || status=$?
  ((status <= 1)) || fail "Input bump-pattern isn't a valid extended regular expression"
  ((status == 0)) || required=false
  output bump-required "$required"

  local base head
  git cat-file -e "$BASE_SHA:$VERSION_FILE" 2>/dev/null ||
    no_base_version "$required" "$VERSION_FILE doesn't exist in the base commit (${BASE_SHA:0:7})"
  regex_version base "$BASE_SHA"
  base=$out
  regex_version head "$HEAD_SHA"
  head=$out
  output base-version "$base"
  output head-version "$head"
  verdict "$required" "$base" "$head" "$(regex_relation "$base" "$head")"
}

# --- Commitizen mode -----------------------------------------------------------

# cz_increment LAST_RELEASE: store in $out the increment (NONE, PATCH, MINOR or MAJOR)
# that the repo's bump rules give the commits after LAST_RELEASE up to the checked-out
# commit, as `cz bump` counts them. Run it in the private clone: it adds a tag.
cz_increment() {
  # `cz version X --next USE_GIT_COMMITS` applies the repo's bump rules to the
  # commits since the tag for X. Tagging the last release for a placeholder X
  # limits that to the unreleased commits; X's next version reveals the increment.
  local placeholder=1.0.0 next increment=NONE inc
  capture "Formatting a tag with tag_format" cz version "$placeholder" --tag
  git update-ref "refs/tags/$out" "$1" || fail "tag_format produced an invalid tag name: $out"
  capture "Finding the increment for the unreleased commits" cz version "$placeholder" --next USE_GIT_COMMITS
  next=$out
  if [[ $next != "$placeholder" ]]; then
    increment=
    for inc in PATCH MINOR MAJOR; do
      capture "Computing a $inc increment" cz version "$placeholder" --next "$inc"
      if [[ $out == "$next" ]]; then increment=$inc; fi
    done
    [[ -n $increment ]] || fail "Couldn't map next version $next of $placeholder to an increment"
  fi
  out=$increment
}

commitizen_mode() {
  require_bool enforce-increment "$ENFORCE_INCREMENT"
  require_bool check-consistency "$CHECK_CONSISTENCY"

  # Work in a private clone: it shares objects with the checkout, but has no tags
  # and no worktree link, so the synthetic tag below never leaks into the caller.
  local origin work clone
  origin=$(git rev-parse --show-toplevel)
  work=$(mktemp -d)
  # shellcheck disable=SC2064  # expand $work now
  trap "rm -rf '$work'" EXIT
  clone=$work/repo
  git clone --quiet --shared --no-checkout --no-tags "$origin" "$clone"
  cd "$clone"
  checkout() { git -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout --quiet --force --detach "$1"; }
  checkout "$HEAD_SHA"

  local info config provider
  info=$(cz_helper describe) || fail "Reading the Commitizen configuration failed"
  config=$(sed -n 's/^config=//p' <<<"$info")
  provider=$(sed -n 's/^provider=//p' <<<"$info")
  [[ -n $config ]] ||
    fail "No Commitizen configuration found in the head commit; add one, or set version-file to use regex mode"
  [[ $provider != scm ]] ||
    fail "version_provider 'scm' keeps the version in git tags, which a pull request can't change; use another provider or regex mode"
  detail "Commitizen configuration: \`$config\` (version provider: $provider)"
  check_commit_messages

  # The last release is the commit tagged with the base version: `cz bump` counts
  # the commits after it. Without that tag on the base branch, count from the base.
  local base='' head tag commit last_release=$BASE_SHA since="the base commit (${BASE_SHA:0:7})"
  checkout "$BASE_SHA"
  info=$(cz_helper describe) || fail "Reading the Commitizen configuration in the base commit failed"
  if [[ -n $(sed -n 's/^config=//p' <<<"$info") ]]; then
    capture "Reading the version in the base commit (${BASE_SHA:0:7})" cz version --project
    base=$out
    capture "Formatting the tag of the base version" cz version "$base" --tag
    tag=$out
    # The private clone has no tags; look them up in the checkout.
    commit=$(git -C "$origin" rev-parse --quiet --verify "refs/tags/$tag^{commit}" || true)
    if [[ -n $commit ]] && git merge-base --is-ancestor "$commit" "$BASE_SHA"; then
      last_release=$commit since="\`$tag\` (${commit:0:7})"
    else
      since+="; tag \`$tag\` isn't on the base branch"
    fi
  else
    since+="; it has no version"
  fi
  detail "Unreleased commits: since $since"
  checkout "$HEAD_SHA"

  local increment required=true
  cz_increment "$last_release"
  increment=$out
  output increment "$increment"
  detail "Increment required by the unreleased commits: $increment"
  [[ $increment != NONE ]] || required=false
  output bump-required "$required"

  [[ -n $base ]] || no_base_version "$required" \
    "The base commit (${BASE_SHA:0:7}) has no Commitizen configuration, so it has no version to compare"

  local expected='' need='' enforced=''
  capture "Reading the version in the head commit (${HEAD_SHA:0:7})" cz version --project
  head=$out
  output base-version "$base"
  output head-version "$head"
  if [[ $required == true ]]; then
    capture "Computing the expected version" cz version "$base" --next "$increment"
    expected=$out need="a $increment bump to $expected"
    output expected-version "$expected"
  fi
  detail "Versions: base $base, head $head${expected:+, expected $expected}"

  if [[ $required == true && $CHECK_CONSISTENCY == true ]]; then
    local missing
    if ! missing=$(cz_helper consistency "$head"); then
      fail "version_files don't all contain the head version $head" "$missing"
    fi
    detail "version_files: consistent"
  fi

  [[ $ENFORCE_INCREMENT == false ]] || enforced=$expected
  capture "Comparing versions" cz_helper compare "$base" "$head" ${enforced:+"$enforced"}
  verdict "$required" "$base" "$head" "$out" "$need"
}

# --- main ------------------------------------------------------------------------

require_bool check-commits "$CHECK_COMMITS"
[[ -n $BASE_SHA && -n $HEAD_SHA ]] ||
  fail "Inputs base-sha and head-sha are required (they default to the pull_request event's SHAs)"
# Resolve to full SHAs: refs like `main` or `HEAD` mean something else in the private clone.
resolve() { git rev-parse --quiet --verify "$1^{commit}" || true; }
base_commit=$(resolve "$BASE_SHA")
head_commit=$(resolve "$HEAD_SHA")
missing="isn't available; check out the repository with fetch-depth: 0"
[[ -n $base_commit ]] || fail "Commit $BASE_SHA $missing"
[[ -n $head_commit ]] || fail "Commit $HEAD_SHA $missing"
BASE_SHA=$base_commit HEAD_SHA=$head_commit

mode=commitizen
[[ -z $VERSION_FILE ]] || mode=regex
output mode "$mode"
count=$(git rev-list --count "$BASE_SHA..$HEAD_SHA")
detail "Mode: $mode"
detail "Commits checked: $count (\`${BASE_SHA:0:7}..${HEAD_SHA:0:7}\`)"
if ((count == 0)); then
  output bump-required false
  pass "No commits to check"
fi

"${mode}_mode"
