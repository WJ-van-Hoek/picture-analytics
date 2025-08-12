# Release Policy

**Versioning Scheme: Semantic Versioning (SemVer) with Pre-Release Identifiers**

---

## 1. Purpose

This policy defines the rules for versioning, promoting, and rolling back software releases within our delivery pipeline.
The objective is to ensure consistent version naming, predictable promotion from pre-release to General Availability (GA),
and controlled rollback procedures to reduce risk.

---

## 2. Versioning Standard

We follow **[Semantic Versioning 2.0.0](https://semver.org/)**:

```
MAJOR.MINOR.PATCH[-PRERELEASE[.BUILD]]
```

* **MAJOR**: Incompatible API changes or breaking changes in functionality.
* **MINOR**: Backwards-compatible new features or improvements.
* **PATCH**: Backwards-compatible bug fixes.
* **PRERELEASE** *(optional)*: Indicates an unstable build prior to GA (e.g., `alpha`, `beta`, `rc`).
* **BUILD** *(optional)*: Incremental build or iteration number (e.g., `.1`, `.2`).

### Examples

* Stable release: `1.4.0`
* Alpha pre-release: `1.4.0-alpha.1`
* Beta pre-release: `1.4.0-beta.2`
* Release Candidate: `1.4.0-rc.1`

---

## 3. Pre-Release Stages and Promotion Rules

| Stage                         | Stability Level                                  | Intended Audience                            | Promotion Criteria                                             |
| ----------------------------- | ------------------------------------------------ | -------------------------------------------- | -------------------------------------------------------------- |
| **Alpha**                     | Low — experimental, unstable                     | Internal developers & testers                | Features merged and build passes CI; no production SLA         |
| **Beta**                      | Medium — feature-complete, may have known issues | Selected external testers or pilot customers | Alpha feedback addressed; automated and exploratory tests pass |
| **RC (Release Candidate)**    | High — stable pending sign-off                   | Broader testing; limited production pilots   | Zero critical defects; regression suite passes                 |
| **GA (General Availability)** | Production-ready                                 | All customers                                | Formal change approval; compliance/security checks pass        |

**Promotion Rules**:

1. **Alpha → Beta**:

   * All planned features for the release are implemented.
   * Unit, integration, and smoke tests pass.
   * Known issues documented.

2. **Beta → RC**:

   * No open P1/P2 defects.
   * Performance benchmarks meet acceptance criteria.
   * All security scans pass with no high-severity vulnerabilities.

3. **RC → GA**:

   * Approved by Change Advisory Board (CAB) or designated release approvers.
   * Deployment verified in staging environment with production-like data.

---

## 4. Tagging & Branching Guidelines

* Tags follow the **exact version string** (e.g., `v1.4.0-alpha.1`).
* Pre-release builds originate from dedicated pre-release branches (`develop-alpha`, `develop-beta`) or feature branches merged into them.
* GA builds are tagged on the protected `main` branch.

---

## 5. Rollback Policy

### 5.1 Triggers for Rollback

* Critical defect in production impacting customer operations.
* Security vulnerability requiring immediate mitigation.
* Deployment failure with no viable hotfix in < 2 hours.

### 5.2 Rollback Procedures

1. **Identify last known good version** (GA or stable pre-release).
2. **Redeploy** using the stored release artifact from that version.
3. **Tag** rollback with `-rollback.Y` suffix (e.g., `v1.4.0-rollback.1`).
4. **Document** root cause and corrective actions in release notes.
5. **Apply hotfix** on a separate branch (`hotfix/x.y.z`) and re-promote using standard process.

---

## 6. Compliance & Governance

* All releases must have corresponding release notes.
* All tags must be signed (`git tag -s`).
* Security, quality, and compliance gates must pass prior to promotion.
* Release policy reviewed **annually** or when significant process changes occur.

---

**Effective Date**: *2025-08-12*  
**Approved By**: *Willem*
