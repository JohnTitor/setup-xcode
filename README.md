# setup-xcode

Fast Xcode selection for GitHub Actions.

This action switches between preinstalled Xcode apps on macOS runners. It is optimized for GitHub-hosted images and also works in self-hosted environments when Xcode apps live in searchable directories.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `xcode-version` | no | `latest-stable` | Selector: `latest`, `latest-stable`, `16`, `16.4`, `16.4.0`, `16.4-beta` |

## Outputs

| Output | Description |
| --- | --- |
| `version` | Resolved Xcode version (normalized, e.g. `16.4.0`) |
| `path` | Resolved Xcode app path |

## Selector behavior

- `latest`: newest version, including prerelease builds.
- `latest-stable`: newest stable version only.
- `16`, `16.4`, `16.4.0`: highest stable match for that prefix/exact version.
- `16.4-beta`: highest prerelease match for that prefix/exact version.

### Not supported

Complex semver ranges are currently not supported, such as:

- `^16.4.0`
- `~16.4`
- `>=16`

## Usage

```yaml
jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: JohnTitor/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - run: xcodebuild -version
```

Specific version:

```yaml
- uses: JohnTitor/setup-xcode@v1
  with:
    xcode-version: '16.4'
```

Prerelease:

```yaml
- uses: JohnTitor/setup-xcode@v1
  with:
    xcode-version: '16.4-beta'
```

## Self-hosted runners

By default, the resolver scans `/Applications`.

To scan custom directories, set:

- `SETUP_XCODE_SEARCH_DIRS=/Applications,/opt/Xcodes`

It accepts a comma-separated list of directories.

## Environment variables used

- `MD_APPLE_SDK_ROOT` is exported to the selected Xcode app path for downstream steps.

## Benchmarking

A benchmark workflow is included (`.github/workflows/benchmark.yml`) and uses `scripts/benchmark.sh` to compare median runtime against `maxim-lobanov/setup-xcode@v1` on the same macOS runner class.

## License

MIT
