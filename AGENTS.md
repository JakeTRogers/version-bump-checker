# version-bump-checker

A composite GitHub Action (`uses: JakeTRogers/version-bump-checker@<sha>`) that fails a PR
whose commits call for a release when the project version didn't increase. Usage, inputs and
outputs are in `README.md`.

## Commands

- Test: `tests/run.sh` (filter by name: `tests/run.sh cz_`; `JOBS=n` limits parallelism;
  `COMMITIZEN_VERSION=4.17.0 tests/run.sh` tests the oldest supported Commitizen)
- Lint: `pre-commit run --all-files` (shellcheck, actionlint, pre-commit-hooks, and the tests)
- Run against a local repo: `BASE_SHA=main HEAD_SHA=HEAD ./check.sh` from inside that repo

## Architecture

- `action.yml`: installs uv (only when Commitizen is needed) and runs `check.sh`. Every input
  reaches the script through `env:`; never interpolate `${{ inputs.* }}` into `run:`.
- `check.sh`: all the logic. Defaults live here, not in `action.yml` (inputs default to `""`).
  Regex mode when `VERSION_FILE` is set, otherwise Commitizen mode. Each mode reports facts
  (bump required, base and head versions, how they compare); `verdict` alone decides pass or fail.
- `cz_helper.py`: what the `cz` CLI can't do (read the config, compare versions with the
  repo's `version_scheme`, check `version_files`). Uses only `commitizen.config.read_cfg`
  and `commitizen.version_schemes.get_version_scheme`, which are stable since 4.17.0.
- `tests/run.sh`: builds throwaway git repos per scenario (functions named `t_*`) and runs
  `check.sh` under `bash --noprofile --norc -eo pipefail`, GitHub's `shell: bash`.
- `.github/workflows/ci.yml`: lint, tests (default and minimum Commitizen), and `uses: ./`
  on this repo's PRs. `release.yml`: on a `vX.Y.Z` tag, publish the release from
  `CHANGELOG.md` and move the major tag. It's the only workflow with `contents: write`.

## How Commitizen mode finds the increment

The increment covers the *unreleased commits* (see `GLOSSARY.md`): everything after the
base version's tag, as `cz bump` counts them, so release commits merged without a bump count.
`cz bump --get-next`/`--dry-run` can't be used: they read commits since the *current
version's tag*, which doesn't exist once the PR has its bump commit. Instead, `check.sh`
makes a private `git clone --shared --no-tags`, points the tag for a placeholder version
(1.0.0, via `cz version 1.0.0 --tag`) at the last release, and runs
`cz version 1.0.0 --next USE_GIT_COMMITS` (Commitizen 4.17.0+). Comparing that with
`--next PATCH|MINOR|MAJOR` gives the increment. A placeholder is used instead of the base
version because a prerelease base can't tell `docs:` from `fix:`
(`1.3.0-rc1 --next` is `1.3.0` either way).

The last release is the base version's tag, looked up in the caller's checkout (the clone
has no tags) and used only when it's an ancestor of the base commit. Otherwise (tag not
pushed yet, or left behind by a squash merge) the placeholder tag goes on the base commit and
only the PR's own commits count.

## Conventions

- Conventional Commits, small and focused. The `commitizen` commit-msg hook enforces it.
  Commits and tags are GPG-signed by the maintainer; leave committing to them.
- Pin third-party actions and hooks by commit SHA with a `# vX.Y.Z` / `# frozen: vX.Y.Z`
  comment. Dependabot updates actions, hooks and the dev container images monthly.
- Add a `t_*` function to `tests/run.sh` for each behavior change; use `expect`,
  `expect_output`, `expect_log` and `expect_summary`.

## Gotchas

- Pipes under `pipefail`: `git log | grep -q` (or `| head`) can SIGPIPE the writer and turn
  a match into a failure. Use a here-string or a reader that consumes all input.
- `cz version --project` reports some errors on stderr with exit status 0; `capture`
  in `check.sh` treats empty output as a failure.
- Don't run `cz bump` on PR content in the action: it runs changelog generation and the
  PR's `pre_bump_hooks`. That's why `cz_helper.py consistency` reimplements
  `--check-consistency`.
- The uv version is pinned in `action.yml` (`version:` of setup-uv), and the default
  Commitizen version in `check.sh` (`DEFAULT_COMMITIZEN_VERSION`). Dependabot updates neither.
- `.cz.yaml` `version_files` rewrites every README line that mentions
  `JakeTRogers/version-bump-checker` and contains the current version.

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues, using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels, each named after its role. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
