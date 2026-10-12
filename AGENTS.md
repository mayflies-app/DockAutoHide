# Agent Instructions

- Use `./scripts/app.py build|run|test|package` and `release --dry-run`. Codex Run uses `./scripts/app.py run`. See [Development](docs/development.md).
- Keep product behavior and targeted checks in this repository. Maintain common scripts in `homebrew-tap/templates/macos-app/scripts` and synchronize consumers. Use the existing common entrypoint.
- Preserve Dock control, overlap geometry, display selection, authorization, manual control and policy start/stop behavior. Injected tests must not change real Dock settings or login items.
- Maintain English and Simplified Chinese UI with immediate language changes. See [Localization](docs/localization.md).
- Verify affected failure modes with isolated data and fresh output. Use a visible desktop for native checks that require it, and retain inspectable results outside source files.
- Protect unrelated changes and stage only task-owned files. Local builds, tests, packages and commits do not authorize remote writes, notarization or publication.
