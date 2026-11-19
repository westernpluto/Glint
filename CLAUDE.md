# Glint — project rules

- Bundle ID prefix is `com.glint` (app: `com.glint.Glint`). Don't change it unless asked.
- **Every change must bump the version** in `project.yml`:
  - `MARKETING_VERSION`: patch bump by default (1.0.1 → 1.0.2); minor/major for larger feature releases.
  - `CURRENT_PROJECT_VERSION`: increment by 1.
- The app is built only by `.github/workflows/build.yml` on the `xcode-27` runner (XcodeGen → unsigned `.ipa`). After pushing, check that the workflow run succeeds.
