# Releasing

Everyday development needs no ceremony: commit and push to `main`. A release is only
for marking a stable point and shipping a prebuilt app.

Versions follow [semantic versioning](https://semver.org): `vMAJOR.MINOR.PATCH` —
patch for fixes, minor for new mappings/features, major for breaking changes.

## Cutting `vX.Y.Z`

1. **Bump the version** in `Resources/Info.plist`: set `CFBundleShortVersionString`
   to `X.Y.Z` and increment `CFBundleVersion` by 1. Commit and push.

2. **Build and zip** (on an Apple Silicon Mac):

   ```bash
   bash scripts/build-app.sh
   ditto -c -k --keepParent .build/release/VibeController.app VibeController-vX.Y.Z-arm64.zip
   ```

   `ditto` (not plain `zip`) preserves the code signature and extended attributes.

3. **Tag and publish** — `gh release create` makes the tag on GitHub in the same step:

   ```bash
   gh release create vX.Y.Z --target main \
     --title "vX.Y.Z" --notes "..." \
     VibeController-vX.Y.Z-arm64.zip
   ```

Release notes should always repeat the install caveat: the app is **ad-hoc signed**,
so downloaders must clear quarantine once
(`xattr -dr com.apple.quarantine VibeController.app`) and re-grant Accessibility —
see [`install.md`](install.md) and [`pitfalls.md`](pitfalls.md).

The landing page's download button points at `releases/latest`, so it needs no
update when a new version ships.
