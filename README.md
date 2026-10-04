# Dock-Exposé website

This is the website for [dockexpose.netlify.app](https://dockexpose.netlify.app).

The current release is Dock Exposé 4.00.1. The downloadable app is published as a GitHub Release in this repository; the app itself is closed source.

See the [permissions guide](https://dockexpose.netlify.app/docs/permissions) and [compatibility information](https://dockexpose.netlify.app/#introduction) before installing.

## Publishing a release

The release script signs an archive, updates the appcast and current-release website information, and can generate release notes from `git log` since the last `v*` tag:

```sh
scripts/publish-release.sh 4.00.1 Dock-Expose-4.00.1.zip \
  --generate-notes \
  --tag \
  --push-site \
  --create-release
```

`--tag` creates an annotated `vVERSION` tag. With `--push-site`, that tag is pushed along with the website branch; use `--push-tag` instead when pushing only the tag. The script does not build the app or change the Xcode project version; it reads and validates the version/build embedded in the supplied archive. `--build-version` is available only as an explicit override.
