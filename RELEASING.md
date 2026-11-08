# Releasing

1. Merge the changes into `master` and make sure the `test` workflow is green.
2. Pick the version ([semver](https://semver.org/)): bug fixes → patch, new options/features → minor,
   anything that needs users to change their setup → major.
3. Tag and push:
   ```bash
   git checkout master && git pull --ff-only
   git tag -a v1.0.0 -m "v1.0.0"
   git push origin v1.0.0
   ```
4. The `image` workflow tests the tag, publishes the image tags and creates the GitHub Release with the
   list of merged PRs. Edit the release afterwards if something needs a note (e.g. a breaking change).

Only plain `vX.Y.Z` tags are released; other tags (e.g. `v1.1.0-rc1`) are ignored by CI.
