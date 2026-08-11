# Contributing to Lidless

Issues and pull requests are welcome on GitHub. Before opening a change, please
search the existing issues and describe the user-visible problem it solves.

## Development

Lidless requires macOS 13 or newer and the Xcode command line tools.

```bash
./tests/run.sh
OUT=dist ./build.sh
```

Parsing fixes must include a sanitized fixture and a regression test that fails
without the fix. Changes to power, shutdown or display recovery must preserve the
safety invariants documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

The maintainer develops in a private GitLab repository and publishes reviewed
snapshots to GitHub. GitHub pull requests are reviewed publicly, then applied to
the canonical repository with the contributor's authorship preserved before the
next snapshot is published.

## License of contributions

By submitting a contribution, you agree to license it under
`GPL-3.0-only`, the same license as the project. No separate contributor license
agreement is required.
