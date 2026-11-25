#!/usr/bin/env bash
# Runs check.sh against throwaway git repositories.
# Usage: tests/run.sh [NAME_FILTER]   (needs git and uv; JOBS sets parallelism)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK=$ROOT/check.sh
COMMITIZEN_VERSION=${COMMITIZEN_VERSION:-$(sed -n 's/^DEFAULT_COMMITIZEN_VERSION=//p' "$CHECK")}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Keep host git settings (signing, hooks, templates) away from the test repos.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 COMMITIZEN_VERSION
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY

REGEX_ENV=(VERSION_FILE=cmd/version.go 'VERSION_PATTERN=^var version = "\K[^"]+')

# --- helpers -------------------------------------------------------------------

# new_repo: create an empty repository and cd into it.
new_repo() {
  cd "$(mktemp -d "$TMP/repo.XXXX")"
  git init --quiet --initial-branch=main
  git config user.name Test
  git config user.email test@example.com
  git config commit.gpgsign false
  git config tag.gpgsign false
  git config core.hooksPath /dev/null
}

# commit MESSAGE: commit all changes (or nothing) with MESSAGE.
commit() {
  git add --all
  git commit --quiet --allow-empty --file=- <<<"$1"
}

# branch: start the PR branch at the current commit, which becomes the base.
branch() { git checkout --quiet -B pr; }

go_version() {
  mkdir -p cmd
  printf 'package cmd\n\nvar version = "%s"\n' "$1" >cmd/version.go
}

# cz_config VERSION [YAML_LINE...]: write .cz.yaml; extra lines are indented 2 spaces.
cz_config() {
  {
    # shellcheck disable=SC2016  # $version is Commitizen's placeholder
    printf 'commitizen:\n  name: cz_conventional_commits\n  tag_format: v$version\n'
    printf '  version: %s\n  version_scheme: semver\n' "$1"
    if (($# > 1)); then printf '  %s\n' "${@:2}"; fi
  } >.cz.yaml
}

cz_bump() {
  sed -i "s/^  version: .*/  version: $1/" .cz.yaml
  commit "bump: version → $1"
}

# expect STATUS [VAR=value...]: run check.sh for main..HEAD and assert its status.
expect() {
  local want=$1 status=0
  shift
  : >"$OUT"
  env BASE_SHA="$(git rev-parse main)" HEAD_SHA="$(git rev-parse HEAD)" \
    GITHUB_OUTPUT="$OUT" GITHUB_STEP_SUMMARY="$SUMMARY" "$@" \
    bash --noprofile --norc -eo pipefail "$CHECK" >"$LOG" 2>&1 || status=$?
  if [[ $status != "$want" ]]; then
    echo "expected exit status $want, got $status"
    return 1
  fi
}

regex() { expect "$1" "${REGEX_ENV[@]}" "${@:2}"; }

expect_output() {
  grep -qxF -- "$1=$2" "$OUT" || {
    echo "expected output $1=$2"
    return 1
  }
}

expect_log() {
  grep -qF -- "$1" "$LOG" || {
    echo "expected the log to contain: $1"
    return 1
  }
}

expect_summary() {
  grep -qF -- "$1" "$SUMMARY" || {
    echo "expected the job summary to contain: $1"
    return 1
  }
}

# --- regex mode ------------------------------------------------------------------

regex_repo() {
  new_repo
  go_version "${1:-1.2.3}"
  commit "feat: initial"
  branch
}

t_regex_no_release_commits() {
  regex_repo
  commit "ci: pipeline"
  commit $'docs: notes\n\nmention fix: inline'
  commit "bump: nothing to see"
  regex 0
  expect_output bump-required false
}

t_regex_release_commits_without_bump() {
  regex_repo
  local message
  for message in "feat: a" "fix(deps): b" "refactor: c" "perf: d" "ci(actions)!: e" \
    "feat(a)!: f" $'docs: g\n\nBREAKING CHANGE: h' $'docs: i\n\nBREAKING-CHANGE: j' \
    $'docs: k\n\nfix: in the body'; do
    git checkout --quiet -B pr main
    commit "$message"
    regex 1 || {
      echo "commit message: $message"
      return 1
    }
  done
  expect_log "must increase (base: 1.2.3, head: 1.2.3)"
}

t_regex_bump_then_docs() {
  regex_repo
  commit "feat: thing"
  go_version 1.3.0
  commit "bump: version 1.2.3 → 1.3.0"
  commit "docs: later"
  regex 0
  expect_output head-version 1.3.0
}

t_regex_fix_then_docs_without_bump() {
  regex_repo
  commit "fix: thing"
  commit "docs: later"
  regex 1
}

t_regex_version_ordering() {
  local case base head want
  for case in "1.2.3 1.2.2 1" "1.2.3 1.2.10 0" "1.2.3 1.3.0-rc1 0" "1.3.0-rc1 1.3.0 0" \
    "1.3.0-rc2 1.3.0-rc10 0" "1.3.0 1.3.0-rc1 1" "1.2.3 1.2.3+build.5 1"; do
    read -r base head want <<<"$case"
    regex_repo "$base"
    commit "fix: thing"
    go_version "$head"
    commit "bump: version"
    regex "$want" || {
      echo "base $base, head $head"
      return 1
    }
  done
}

# Without release commits the version must not change, except to finalize a prerelease.
t_regex_unwarranted_bump() {
  local case base head want
  for case in "1.2.3 1.2.3 0" "1.3.0-rc1 1.3.0 0" "1.3.0-rc1+b.1 1.3.0 0" "1.2.3 1.2.4 1" \
    "1.3.0-rc1 1.3.0-rc2 1" "1.3.0-rc1 1.3.1 1" "1.2.3 1.2.3+build.5 1" "1.2.3 1.2.2 1"; do
    read -r base head want <<<"$case"
    regex_repo "$base"
    commit "docs: thing"
    go_version "$head"
    commit "bump: version"
    { regex "$want" && expect_output bump-required false; } || {
      echo "base $base, head $head"
      return 1
    }
  done
  expect_log "Version must not change when no unreleased commits require a bump (base: 1.2.3, head: 1.2.2)"
  expect_summary "Version file: \`cmd/version.go\`"
}

t_regex_version_file_added() {
  new_repo
  commit "docs: readme"
  branch
  go_version 1.0.0
  commit "chore: add version"
  regex 0
  expect_output bump-required false
  commit "feat: thing"
  regex 1
  expect_log "doesn't exist in the base commit"
}

t_regex_unrelated_version_text() {
  regex_repo
  commit "fix: thing"
  printf '// var version = "9.9.9"\n' >>cmd/version.go
  commit "docs: comment"
  regex 1
}

t_regex_pattern_matches_twice() {
  regex_repo
  commit "fix: thing"
  printf 'package cmd\n\nvar version = "1.2.4"\nvar version = "1.2.4"\n' >cmd/version.go
  commit "bump: version"
  regex 1
  expect_log "Expected exactly one version-pattern match"
}

t_regex_missing_version_file() {
  regex_repo
  git rm --quiet cmd/version.go
  commit "fix: drop version"
  regex 1
  expect_log "doesn't exist in the head commit"
}

# git log output far beyond a pipe buffer, with the bump-worthy commit newest:
# `git log | grep -q` would get SIGPIPE here and, with pipefail, see no match.
many_commits() {
  local i body
  body=$(printf 'long body line %s\n' {1..40})
  for i in {1..299}; do
    git commit --quiet --allow-empty --file=- <<<"docs: commit $i"$'\n\n'"$body"
  done
}

t_regex_many_commits_with_bump() {
  regex_repo
  many_commits
  go_version 1.3.0
  commit "bump: version 1.2.3 → 1.3.0"
  commit "feat: newest"
  regex 0
  expect_output bump-required true
}

t_regex_many_commits_without_bump() {
  regex_repo
  many_commits
  commit "feat: newest"
  regex 1
}

t_regex_bad_inputs() {
  regex_repo
  commit "fix: thing"
  expect 1 VERSION_FILE=cmd/version.go
  expect_log "version-pattern is required"
  regex 1 'BUMP_PATTERN=('
  expect_log "isn't a valid extended regular expression"
}

# --- Commitizen mode ---------------------------------------------------------------

cz_repo() {
  new_repo
  cz_config "$@"
  commit "feat: initial"
  git tag "v$1"
  branch
}

t_cz_no_release_commits() {
  cz_repo 1.2.3
  commit "ci: pipeline"
  commit $'docs: notes\n\nmention fix: inline'
  expect 0
  expect_output increment NONE
  expect_output bump-required false
}

t_cz_release_commits_without_bump() {
  cz_repo 1.2.3
  local case message increment
  for case in "feat: a|MINOR" "fix(deps): b|PATCH" "refactor: c|PATCH" "perf: d|PATCH" \
    "ci(actions)!: e|MAJOR" "feat(a)!: f|MAJOR" $'docs: g\n\nBREAKING CHANGE: h|MAJOR' \
    $'docs: i\n\nBREAKING-CHANGE: j|MAJOR' $'docs: k\n\nfix: in the body|PATCH'; do
    message=${case%|*} increment=${case##*|}
    git checkout --quiet -B pr main
    commit "$message"
    { expect 1 && expect_output increment "$increment"; } || {
      echo "commit message: $message"
      return 1
    }
  done
}

t_cz_bump_then_docs() {
  cz_repo 1.2.3
  commit "feat: thing"
  cz_bump 1.3.0
  commit "docs: later"
  expect 0
  expect_output expected-version 1.3.0
  expect_output head-version 1.3.0
}

t_cz_fix_then_docs_without_bump() {
  cz_repo 1.2.3
  commit "fix: thing"
  commit "docs: later"
  expect 1
  expect_log "the unreleased commits require a PATCH bump to 1.2.4"
}

# Release commits merged without a bump stay unreleased until a PR bumps, as with `cz bump`.
t_cz_unreleased_commits() {
  cz_repo 1.2.3
  commit "feat: a, merged without a bump"
  commit "fix: b, merged without a bump"
  git branch --force main
  commit "fix: c"
  cz_bump 1.2.4
  expect 1
  expect_output increment MINOR
  expect_output expected-version 1.3.0
  expect_log "Version 1.2.4 is too small; the unreleased commits require a MINOR bump to 1.3.0"
  expect_summary "Unreleased commits: since \`v1.2.3\`"
  cz_bump 1.3.0
  expect 0

  git checkout --quiet -B pr main
  commit "docs: unrelated"
  expect 1
  expect_output increment MINOR
  expect_log "Version must increase (base: 1.2.3, head: 1.2.3)"

  git checkout --quiet -B pr main
  cz_bump 1.3.0
  expect 0
  expect_output bump-required true
}

# A release tag off the base branch (e.g. a squash-merged bump commit's) doesn't
# mark what the base branch released: only the PR's own commits count.
t_cz_release_tag_off_base_branch() {
  new_repo
  cz_config 1.2.3
  commit "feat: initial"
  git checkout --quiet -b side
  commit "feat: bump commit before the squash"
  git tag v1.2.3
  git checkout --quiet main
  commit "feat: squashed"
  branch
  commit "docs: thing"
  expect 0
  expect_output increment NONE
  expect_summary "since the base commit"
  expect_summary "tag \`v1.2.3\` isn't on the base branch"
}

t_cz_version_ordering() {
  local case base message head want
  for case in "1.2.3|fix: a|1.2.2|1" "1.2.3|fix: a|1.2.10|0" "1.2.3|feat: a|1.3.0-rc1|0" \
    "1.3.0-rc1|docs: a||0" "1.3.0-rc1|fix: a|1.3.0-rc2|0" "1.3.0-rc1|fix: a|1.3.0|0" \
    "1.3.0-rc1|fix: a||1"; do
    IFS='|' read -r base message head want <<<"$case"
    cz_repo "$base"
    commit "$message"
    if [[ -n $head ]]; then cz_bump "$head"; fi
    expect "$want" || {
      echo "base $base, '$message', head ${head:-unchanged}"
      return 1
    }
  done
}

# Without release commits the version must not change, except to finalize a prerelease.
t_cz_unwarranted_bump() {
  local case base head want
  for case in "1.3.0-rc1|1.3.0rc1|0" "1.3.0-rc1|1.3.0|0" "1.2.3|1.2.4|1" "1.3.0-rc1|1.3.0-rc2|1" \
    "1.3.0-rc1|1.3.1|1" "1.2.3|1.2.2|1"; do
    IFS='|' read -r base head want <<<"$case"
    cz_repo "$base"
    commit "docs: thing"
    cz_bump "$head"
    { expect "$want" && expect_output bump-required false; } || {
      echo "base $base, head $head"
      return 1
    }
  done
  expect_log "Version must not change when no unreleased commits require a bump (base: 1.2.3, head: 1.2.2)"
  expect_output head-version 1.2.2
}

# Commitizen's semver scheme orders 1.2.3+build.5 above 1.2.3, so only enforce-increment
# stops it; regex mode ignores +build metadata (t_regex_version_ordering).
t_cz_build_metadata() {
  cz_repo 1.2.3
  commit "fix: thing"
  cz_bump 1.2.3+build.5
  expect 1
  expect_log "Version 1.2.3+build.5 is too small; the unreleased commits require a PATCH bump to 1.2.4"
  expect 0 ENFORCE_INCREMENT=false
}

t_cz_config_added() {
  new_repo
  commit "docs: readme"
  branch
  cz_config 1.0.0
  commit "chore: add commitizen"
  expect 0
  expect_output bump-required false
  commit "feat: thing"
  expect 1
  expect_log "has no Commitizen configuration, so it has no version to compare"
}

t_cz_increment_too_small() {
  cz_repo 1.2.3
  commit "feat: thing"
  cz_bump 1.2.4
  expect 1
  expect_log "Version 1.2.4 is too small; the unreleased commits require a MINOR bump to 1.3.0"
  expect 0 ENFORCE_INCREMENT=false

  git checkout --quiet -B pr main
  commit $'fix: thing\n\nBREAKING CHANGE: gone'
  cz_bump 1.3.0
  expect 1
  expect_output expected-version 2.0.0
}

t_cz_major_version_zero() {
  cz_repo 0.4.0 "major_version_zero: true"
  commit "feat!: break"
  cz_bump 0.5.0
  expect 0
  expect_output increment MINOR
  expect_output expected-version 0.5.0

  cz_repo 0.4.0
  commit "feat!: break"
  cz_bump 0.5.0
  expect 1
  expect_output increment MAJOR
  expect_output expected-version 1.0.0
}

# provider_repo PROVIDER: version 1.2.3 lives in the provider's own file.
provider_repo() {
  new_repo
  case $1 in
  pep621) printf '[project]\nname = "demo"\nversion = "1.2.3"\n' >pyproject.toml ;;
  npm) printf '{\n  "name": "demo",\n  "version": "1.2.3"\n}\n' >package.json ;;
  cargo) printf '[package]\nname = "demo"\nversion = "1.2.3"\n' >Cargo.toml ;;
  esac
  printf 'commitizen:\n  version_provider: %s\n' "$1" >.cz.yaml
  commit "feat: initial"
  branch
}

t_cz_version_providers() {
  local provider file
  for provider in pep621 npm cargo; do
    provider_repo "$provider"
    commit "feat: thing"
    expect 1 || {
      echo "provider $provider without bump"
      return 1
    }
    file=$(git ls-files | grep -vxF .cz.yaml)
    sed -i 's/1\.2\.3/1.3.0/' "$file"
    commit "bump: version 1.2.3 → 1.3.0"
    { expect 0 && expect_output head-version 1.3.0; } || {
      echo "provider $provider with bump"
      return 1
    }
  done
}

t_cz_scm_provider_unsupported() {
  new_repo
  printf 'commitizen:\n  version_provider: scm\n' >.cz.yaml
  commit "feat: initial"
  git tag v1.2.3
  branch
  commit "feat: thing"
  expect 1
  expect_log "version_provider 'scm' keeps the version in git tags"
}

t_cz_consistency() {
  cz_repo 1.2.3 "version_files:" "- VERSION" "- README.md:^Version"
  printf '1.2.3\n' >VERSION
  printf 'Version 1.2.3\nOther 1.2.3\n' >README.md
  commit "docs: add version files"
  git branch --force main
  commit "feat: thing"
  cz_bump 1.3.0
  expect 1
  expect_log "VERSION (version 1.3.0 not found)"
  expect_log "README.md (version 1.3.0 not found)"
  expect 0 CHECK_CONSISTENCY=false

  printf '1.3.0\n' >VERSION
  printf 'Version 1.3.0\nOther 1.2.3\n' >README.md
  commit "fix: update version files"
  expect 0
}

t_cz_check_commits() {
  cz_repo 1.2.3
  commit "not a conventional commit"
  expect 0
  expect 1 CHECK_COMMITS=true
  expect_log "commit validation: failed!"
}

t_cz_custom_rules() {
  new_repo
  printf '%s\n' "commitizen:" "  name: cz_customize" "  version: 1.2.3" "  customize:" \
    "    bump_pattern: '^(docs|feat)'" "    bump_map:" "      docs: PATCH" "      feat: MINOR" >.cz.yaml
  commit "feat: initial"
  branch
  commit "docs: now releases a patch"
  expect 1
  expect_output increment PATCH
  commit "fix: not in the custom rules"
  cz_bump 1.2.4
  expect 0
}

t_cz_missing_config() {
  new_repo
  commit "feat: initial"
  branch
  commit "feat: thing"
  expect 1
  expect_log "No Commitizen configuration found"
}

t_cz_base_commits_after_last_tag() {
  # The base version 1.1.0 has no tag yet (it's pushed after the merge), and
  # v1.0.0 (also the placeholder's tag name) is older: only the PR's own commits count.
  cz_repo 1.0.0
  commit "feat: unreleased on main"
  cz_bump 1.1.0
  git branch --force main
  commit "docs: only docs in the PR"
  expect 0
  expect_output increment NONE
  expect_summary "tag \`v1.1.0\` isn't on the base branch"
  commit "fix: thing"
  expect 1
  expect_output increment PATCH
  expect_output expected-version 1.1.1
  [[ $(git tag) == v1.0.0 ]] || {
    echo "check.sh changed the caller's tags: $(git tag | xargs)"
    return 1
  }
}

# --- both modes ---------------------------------------------------------------------

t_empty_range() {
  cz_repo 1.2.3
  expect 0
  expect_log "No commits to check"
}

t_symbolic_refs() {
  cz_repo 1.2.3
  commit "fix: thing"
  cz_bump 1.2.4
  expect 0 BASE_SHA=main HEAD_SHA=HEAD
  expect_output base-version 1.2.3
}

t_bad_inputs() {
  cz_repo 1.2.3
  commit "feat: thing"
  expect 1 BASE_SHA=
  expect_log "base-sha and head-sha are required"
  expect 1 CHECK_COMMITS=yes
  expect_log "check-commits must be 'true' or 'false'"
  expect 1 HEAD_SHA=0123456789abcdef0123456789abcdef01234567
  expect_log "fetch-depth: 0"
}

# --- runner ----------------------------------------------------------------------------

# Install Commitizen once, so the parallel tests share the cached environment.
uvx --quiet --from "commitizen==$COMMITIZEN_VERSION" cz version >/dev/null

mapfile -t tests < <(declare -F | awk '{print $3}' | grep '^t_' | grep -- "${1:-}" || true)
if ((${#tests[@]} == 0)); then
  echo "No tests match '${1:-}'"
  exit 1
fi

max_jobs=${JOBS:-$(nproc)}
for t in "${tests[@]}"; do
  while (($(jobs -rp | wc -l) >= max_jobs)); do wait -n || true; done
  {
    set +e
    (
      set -e
      LOG=$TMP/$t.log OUT=$TMP/$t.out SUMMARY=$TMP/$t.summary
      "$t"
    ) >"$TMP/$t.result" 2>&1
    echo $? >"$TMP/$t.status"
  } &
done
wait

failed=0
for t in "${tests[@]}"; do
  if [[ $(<"$TMP/$t.status") == 0 ]]; then
    echo "ok   ${t#t_}"
    continue
  fi
  failed=$((failed + 1))
  echo "FAIL ${t#t_}"
  sed 's/^/     /' "$TMP/$t.result"
  if [[ -s $TMP/$t.log ]]; then
    echo "     --- check.sh output:"
    sed 's/^/     /' "$TMP/$t.log"
  fi
done
echo "$((${#tests[@]} - failed)) passed, $failed failed"
((failed == 0))
