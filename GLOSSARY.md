# Version bump checking

Checks that a pull request whose commits require a new version also raises the project
version.

## Language

### Comparison

**Base commit**:
The commit a pull request is compared against: by default the tip of its base branch, not the
merge base.
_Avoid_: base branch (when you mean the commit), merge base

**Head commit**:
The pull request's latest commit, whose version is checked.
_Avoid_: PR branch (when you mean the commit)

**Base version** / **Head version**:
The project version in the base commit / head commit.

### Commits

**Commit rules**:
A named rule set, such as `cz_conventional_commits`, that says which commit messages are valid
and holds the bump rules.
_Avoid_: Commitizen rules

**Bump rules**:
The rules that map commit messages to an increment; in regex mode, the bump pattern.
_Avoid_: Commitizen rules

**Release commit**:
A commit whose message requires a bump under the bump rules.

**Bump commit**:
A commit that changes the project version.

**Last release**:
The commit tagged with the base version.
_Avoid_: last tag (any tag isn't necessarily the base version's)

**Unreleased commits**:
The commits after the last release up to the head commit: release commits merged to the base
branch without a bump, and the pull request's own. In regex mode, only the pull request's own.
_Avoid_: pending commits, PR commits (when you mean all of them)

### Versions

**Release**:
A new version of the project.

**Version core**:
The `MAJOR.MINOR.PATCH` part of a version, without its prerelease or build suffix.
_Avoid_: release, release part, release segment

**Increment**:
The size of version change the unreleased commits require: `NONE`, `PATCH`, `MINOR` or
`MAJOR`.
_Avoid_: bump type, bump level

**Bump**:
The version change a pull request makes, from base version to head version.
_Avoid_: increment (that's what the commits require)

**Unwarranted bump**:
A bump when no unreleased commit is a release commit, other than a finalization.
_Avoid_: stray bump, extra bump

**Finalization**:
A bump from a prerelease to its version core, such as `1.3.0-rc1` → `1.3.0`.
_Avoid_: graduation

**Expected version**:
The version the increment leads to from the base version. A target for the head version's
core, not a lower bound: `1.3.0-rc1` meets an expected `1.3.0`.
_Avoid_: minimum version, smallest version

### Modes

**Commitizen mode**:
Takes the version, commit rules and bump rules from the repository's own Commitizen
configuration.

**Regex mode**:
Reads the version from one file with a pattern, and recognizes release commits with the bump
pattern; for repositories without Commitizen.
