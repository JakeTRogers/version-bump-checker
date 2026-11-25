# Bumps follow `cz bump` over the unreleased commits

A pull request passes when its head version reaches what `cz bump` would produce at its head.
It fails when it changes the version where `cz bump` would find nothing to release. So the
increment covers the unreleased commits: everything after the last release, the commit tagged
with the base version. That includes release commits merged without a bump, not just the
pull request's own. We chose this because Dependabot updates get batched: several are merged
with a bypass and the last one gets the bump, and `cz bump` releases all of them. A check that
counted only the last pull request's commits would accept a patch where `cz bump` gives a
minor.

## Considered Options

- **Count only the pull request's own commits** (the original behavior). Simple, and it needs
  no tags. But it misses release commits merged without a bump: after two bypassed `feat:`
  pull requests, a `fix:` pull request passes with a patch bump.
- **Split the two questions.** The pull request's own release commits would decide whether a
  bump is required, and the unreleased commits would decide the expected version once it
  bumps. Unrelated pull requests keep passing while a release is owed. But it tracks two
  increments, and it still rejects a pull request that only runs `cz bump`.
- **Match `cz bump`** (chosen). One rule and one increment. A pull request that only runs
  `cz bump` is allowed, because `cz bump` would make that bump.

## Consequences

- While release commits sit unreleased on the base branch, every pull request fails until one
  bumps, including unrelated `docs:` ones. Each needs a bump or a bypass.
- A bump with no unreleased release commit is an unwarranted bump and fails. The exception is a
  finalization (`1.3.0-rc1` → `1.3.0`): its release commits were already counted when the
  prerelease was cut. A base commit with no version passes when nothing calls for a release.
- When the base version's tag isn't on the base branch (not pushed yet, or left behind by a
  squash merge), only the pull request's own commits count, and the job summary says so. Right
  after a release that's the correct answer anyway.
- On a pull request branch that wasn't rebased, commits merged to the base branch after it
  branched aren't counted. `cz bump` on that branch wouldn't count them either.
- Regex mode has no tags, so it counts only the pull request's own commits. Release commits
  merged there without a bump are never counted again, and a pull request that only bumps fails.
