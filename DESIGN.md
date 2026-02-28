# Design Notes

## Clean-room intent
This repository intentionally implements `setup-xcode` behavior from scratch.

- No source files were copied from other actions.
- Behavior was specified independently from public runner conventions and action UX goals.
- Internal implementation choices (composite action + Bash resolver + filename-first parsing) are specific to this repository.

## Why this design is fast

1. Candidate discovery only scans explicit directories (`/Applications` by default).
2. Version parsing starts from app names and avoids plist I/O for common runner layouts.
3. Selection computes a best match in one pass, without dependency install or Node startup overhead.

## Compatibility scope

- Supported selectors:
  - `latest`
  - `latest-stable`
  - exact versions: `16`, `16.4`, `16.4.0`
  - prerelease suffix: `16.4-beta`
- Explicitly unsupported in v1:
  - complex semver ranges (`^16.4.0`, `~16.4`, `>=16`)
