# version-bump-checker

A GitHub Action that fails a pull request when its commits call for a release under
[Conventional Commits](https://www.conventionalcommits.org/) rules but the project version
didn't increase compared with the PR's base branch.

- It checks every line of each commit message, so `fix:` body lines and `BREAKING CHANGE:`
  footers count. In Commitizen mode it checks every commit since the base version's tag, as
  `cz bump` does, so release commits merged without a bump still count. In regex mode it
  checks the commits in `base..head`.
- It compares the version in the head commit with the version at the tip of the base branch,
  so a bump in any commit of the PR counts.
- When none of those commits calls for a release, the version must not change, except to
  finalize a prerelease (`1.3.0-rc1` → `1.3.0`).
- It writes a job summary and an `::error::` annotation on failure.

It has two modes:

| Mode | When | Version from | Bump rules |
| --- | --- | --- | --- |
| Commitizen | `version-file` is empty (default) | `cz version --project` (any `version_provider` except `scm`) | the repo's own Commitizen config (`bump_pattern`, `bump_map`, `major_version_zero`, `cz_customize`, …) |
| Regex | `version-file` is set | `version-pattern` matched in `version-file` | `bump-pattern` (defaults to the `cz_conventional_commits` rules) |

## Usage

The caller must check out the PR head with full history (`fetch-depth: 0`), and should not
keep the token in the checkout (`persist-credentials: false`), because the action runs tools
on PR-controlled files.

### Commitizen repositories

```yaml
name: Version Bump Check

on:
  pull_request:
    types: [opened, reopened, synchronize]

permissions:
  contents: read

jobs:
  version-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false

      - uses: JakeTRogers/version-bump-checker@<sha>  # v1.0.0
```

In Commitizen mode the action:

1. reads the version at the base and head commits with `cz version --project`;
2. finds the increment (`NONE`, `PATCH`, `MINOR` or `MAJOR`) that the repo's bump rules give
   the unreleased commits: those after the base version's tag (`v1.2.3`), as `cz bump` counts
   them, or after the base commit when that tag isn't on the base branch (not pushed yet, or
   left behind by a squash merge);
3. when the increment is `NONE`, passes if the version is unchanged under the repo's
   `version_scheme` or finalizes a prerelease (`1.3.0-rc1` → `1.3.0`), and fails otherwise;
4. fails unless the head version is greater under the repo's `version_scheme`, and, with
   `enforce-increment`, its version core reaches the expected version (`1.3.0-rc1` meets
   `1.3.0`);
5. with `check-consistency`, fails when a `version_files` entry doesn't contain the head
   version (what `cz bump --check-consistency` checks, without running a bump);
6. with `check-commits`, fails when `cz check --rev-range base..head` rejects a commit message.

Commitizen runs through `uvx --from commitizen==<version>`. The action installs uv itself.
It ignores uv settings in the checkout (`UV_NO_CONFIG=1`).

### Regex repositories

For repos without a Commitizen configuration:

```yaml
      - uses: JakeTRogers/version-bump-checker@<sha>  # v1.0.0
        with:
          version-file: cmd/version.go
          # PCRE (grep -P) that must match exactly once; \K drops the prefix.
          version-pattern: '^var version = "\K[^"]+'
```

Versions are compared with `sort -V` for the version core and semver rules for
`-prerelease` suffixes (`1.3.0-rc1` < `1.3.0`); `+build` metadata is ignored. When no commit
matches `bump-pattern`, the version text must stay the same, except to finalize a prerelease.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `base-sha` | `github.event.pull_request.base.sha` | Base commit of the comparison. |
| `head-sha` | `github.event.pull_request.head.sha` | Head commit of the comparison. |
| `version-file` | | Regex mode: file holding the version. Empty selects Commitizen mode. |
| `version-pattern` | | Regex mode: PCRE that matches the version exactly once (required with `version-file`). |
| `bump-pattern` | `cz_conventional_commits` rules | Regex mode: ERE checked against every line of each commit message. |
| `commitizen-version` | pinned in `check.sh` | Commitizen version to run; 4.17.0 or later. |
| `enforce-increment` | `true` | Commitizen mode: fail when the bump is smaller than the commits require. |
| `check-consistency` | `true` | Commitizen mode: fail when a `version_files` entry lacks the head version. |
| `check-commits` | `false` | Validate the commit messages with `cz check` (both modes). |

## Outputs

| Output | Description |
| --- | --- |
| `mode` | `commitizen` or `regex`. |
| `bump-required` | `true` when the commits call for a version bump. |
| `increment` | Commitizen mode: `NONE`, `PATCH`, `MINOR` or `MAJOR`, for the unreleased commits. |
| `base-version` | Version in the base commit (empty when there was nothing to compare). |
| `head-version` | Version in the head commit (empty when there was nothing to compare). |
| `expected-version` | Commitizen mode: the version the increment leads to from the base version (set when a bump is required). The head version's core must reach it: `1.3.0-rc1` meets `1.3.0`. |

## Limitations

- `version_provider: scm` isn't supported: the version lives in tags, which a PR can't change.
- Only the commit rules that ship with Commitizen (`cz_conventional_commits`, `cz_jira`,
  `cz_customize`) are available; third-party `cz` plugins aren't installed.
- The PR that adds Commitizen (or the version file) fails if it has release commits, because
  the base has no version.
- A version change needs an unreleased release commit, other than finalizing a prerelease.
  In regex mode only the PR's own commits count, so a PR that only bumps the version fails,
  and release commits merged without a bump are never counted again.
- In Commitizen mode, release commits merged without a bump (with a bypass) stay unreleased:
  every later PR fails until one bumps the version, which a PR that only runs `cz bump` may do.

## Releases and pinning

Releases are tagged `vX.Y.Z`. For each release, the release workflow publishes a GitHub
release from the `CHANGELOG.md` entry and moves the major tag (`v1`) to it.

Pin the action to a commit SHA, with the release in a comment, so Dependabot can update both:

```sh
git ls-remote https://github.com/JakeTRogers/version-bump-checker 'refs/tags/v1.0.0^{}'
```

## Development

The dev container has uv, Commitizen and pre-commit. Run `pre-commit install` once.

```sh
tests/run.sh             # all script tests (JOBS=n limits parallelism)
tests/run.sh cz_         # tests whose name contains cz_
pre-commit run --all-files
```

To release, run `cz bump` on the PR branch. It updates `.cz.yaml`, `CHANGELOG.md` and the
version in the README examples, commits, and creates a signed, annotated `vX.Y.Z` tag. Once
the tagged commit is on `main`, push the tag (`git push origin vX.Y.Z`). The release workflow
rejects tags that aren't on `main`.
