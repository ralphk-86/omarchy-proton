# Releasing

1. Bump the version in `VERSION`, `manifest.json` and `kitVersion` in `VpnWidget.qml`, and add a
   `CHANGELOG.md` entry. `tests/check.sh` checks that they agree.
2. Run the three test layers (see CONTRIBUTING.md). Note the VM suite's result line in the
   changelog entry.
3. If the panel looks different, regenerate `preview.png` in screenshot mode (CONTRIBUTING.md).
4. Commit, tag `vX.Y.Z`, push the tag.
5. If the plugin is listed in the Omarchy plugin marketplace, open a "Plugin verification"
   issue there with the new commit SHA, so the listing moves to the new version.
6. Users update the widget with `omarchy plugin update`; when files under `system/` changed,
   the panel offers "Update the system part".
