# Releasing

1. Bump the version in `VERSION`, `manifest.json` and `kitVersion` in `VpnWidget.qml`, and add a
   `CHANGELOG.md` entry. `tests/check.sh` checks that they agree.
2. Run the three test layers (see CONTRIBUTING.md). Note the VM suite's result line in the
   changelog entry.
3. If the panel looks different, regenerate `preview.png` in screenshot mode (CONTRIBUTING.md).
4. Commit, tag `vX.Y.Z`, push the tag.
5. If the plugin is listed in the Omarchy plugin marketplace, open a "Plugin verification"
   issue there with the new commit SHA, so the listing moves to the new version. The listing's
   name, description and version come from `manifest.json` at the verified commit, so a rename
   shows there only once the new commit is verified. The listing is marked *Manual setup* (a
   maintainer's decision), which means it has no install button: the copy-ready line at the top
   of the README is what users copy. When that line changes, change it in the README's top
   block and its Install section together.
6. Users update the widget with `omarchy plugin update`. The panel offers "Update the system
   part" whenever the installed system part's version differs from `kitVersion`, so after every
   version bump, even one that changed only documentation.
