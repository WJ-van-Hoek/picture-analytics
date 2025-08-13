# Alpha Release Instructions

These steps describe how to prepare, tag, and publish an **Alpha** pre-release using our GitHub Actions workflow and Semantic Versioning (SemVer) policy.

---

## 1. Preconditions

* All features intended for the alpha build are merged into `develop-alpha`.
* CI pipeline is passing (build, unit tests, linting, security scans).
* Known issues are documented in the `CHANGELOG.md` under an **Alpha** section.
* `TEST_PYPI_API_TOKEN` secret is set in repository settings.

---

## 2. Version Numbering

* Follow **Semantic Versioning**: `MAJOR.MINOR.PATCH-alpha.N`
* Increment the `N` (build number) for each subsequent alpha release of the same target version.

  * Example: `1.4.0-alpha.1` → `1.4.0-alpha.2` → `1.4.0-alpha.3`

---

## 3. Branch & Tag

1. Ensure you are on `develop-alpha`:

   ```bash
   git checkout develop-alpha
   git pull origin develop-alpha
   ```
2. Create a signed tag for the release:

   ```bash
   git tag -s v1.4.0-alpha.1 -m "release 1.4.0-alpha.1"
   git push origin v1.4.0-alpha.1
   ```

---

## 4. Workflow Trigger

* Pushing the tag automatically triggers the `release-alpha.yml` workflow.
* The workflow:

  * Builds the package on Python 3.9+
  * Validates metadata (`twine check`)
  * Publishes to TestPyPI **only** from the Python 3.9+ build

---

## 5. Validation

1. Install the package from TestPyPI to confirm:

   ```bash
   pip install --index-url https://test.pypi.org/simple/ --no-deps your-package-name==1.4.0a1
   ```

   *(Note: Pre-release `alpha` in PyPI maps to `a` in Python version specifier.)*
2. Run smoke tests or example scripts to confirm basic functionality.

---

## 6. Post-Release Actions

* Update `CHANGELOG.md` with:

  * Release date
  * Summary of changes
  * Known issues
* Notify stakeholders (Slack, Teams, email) with install instructions and test scope.
* Collect feedback from testers and log issues in GitHub Issues.

---

## 7. Rollback Procedure (Alpha)

If the alpha build is broken:

1. Delete the alpha tag from remote:

   ```bash
   git push --delete origin v1.4.0-alpha.1
   ```
2. Fix issues in `develop-alpha` and re-tag with incremented alpha number.

---

**Effective Date**: *2025-08-12*  
**Maintainer**: *Willem*
