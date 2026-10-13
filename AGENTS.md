# Agent Instructions

- Use `./scripts/app.py build|run|test|package` and `release --dry-run`. Codex Run uses `./scripts/app.py run`. See [Development](docs/development.md).
- Shared scripts, workflows, and declared design and localization helpers are maintained in `homebrew-tap/templates/macos-app`. Update that source and synchronize from the tap checkout after reviewing local and staged changes. See [Shared Maintenance](https://github.com/mayflies-app/homebrew-tap/tree/main/templates/macos-app#shared-maintenance). Keep app configuration, translations, product behavior and targeted checks here. Use the existing common entrypoints.
- Preserve Dock control, overlap geometry, display selection, authorization, manual control and policy start/stop behavior. Injected tests must not change real Dock settings or login items.
- Maintain English and Simplified Chinese UI with immediate language changes. See [Localization](docs/localization.md).
- Match validation to the change. Documentation-only changes need link, path and diff checks; executable changes need affected tests. Native checks use isolated data, a visible desktop when needed and fresh output directories; retain inspectable results.
- Protect unrelated changes and stage only task-owned files. Local builds, tests, packages and commits do not authorize remote writes, notarization or publication.
