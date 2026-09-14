# Security Scan Report

## 2026-09-12 main handoff

Scope: 13 unpublished commits ending at `e6d678b`, plus the documentation-only
handoff update. These checks do not constitute a complete security audit.

- Inspected each unpublished commit diff for high-confidence private-key,
  GitHub-token, AWS-access-key and API-key formats: no matches.
- Checked changed paths for environment files, keys, runtime traces, recordings,
  model weights and archives: none are part of the intended publication.
- Whitespace and edited-document local-link checks passed. The complete test
  suite passed (721 tests / 196.40 seconds), as did the separate release-document
  checks (14 tests).
- Benchmark and design records contain local deployment identifiers, paths and
  short recognition examples for reproducibility. They are documentation, not
  raw session-log uploads; the public README, changelog, API and deployment guide
  retain their separate portable-document checks.
- Unlike the older release below, this main history includes selected tracked
  `docs/superpowers/specs/` records. The ignore rule does not remove documents
  already tracked by Git. Other ignored local notes and private runtime backups
  are not staged or published.
- Only `main` and the existing `pre-qwen-long-speech-20260912` rollback tag are in
  scope. The tag annotation identifies a private backup path but does not contain
  that backup or its service configuration.

## Historical 2026-08-10 release scan

Date: 2026-08-10

Release: unreleased changes after `v0.2.0`
Scope: the intended public source, tests, package metadata, and user-facing
documentation

## Checks

The release review searches for high-confidence credential formats, private-key
headers, private-network addresses, machine-specific paths in user-facing
documentation, sensitive runtime artifacts, and unexpected public URLs.

Representative commands, run from the repository root:

```bash
git grep -nE \
  '(-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|github_pat_|gh[pousr]_|AKIA)' \
  -- . ':(exclude)docs/SECURITY_SCAN.md'

git grep -nE \
  '(192\.168\.|10\.[0-9]+\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' \
  -- README.md CHANGELOG.md pyproject.toml docs voxbridge tests tools

git grep -nE '(^|[^.])/(data|home)/' -- \
  README.md CHANGELOG.md docs/API.md docs/DEPLOYMENT.md

git ls-files | rg \
  '(^|/)(\.env|[^/]+\.(pem|key|log|trace|wav|m4a|mp3|jsonl))$'
```

## Results

1. No concrete API keys, access tokens, private keys, password hashes, or other
   high-confidence credentials were found.
2. No private-network endpoint appears in public documentation or runtime
   defaults. Loopback addresses and the reserved `voxbridge.example.com`
   documentation hostname are intentional. The PCCS listener QR defaults to the
   current request origin and no remote listener address is embedded in runtime code.
3. User-facing documentation contains no machine-specific `/data` or `/home`
   path. Installation and service examples use repository-relative paths or
   `%h`.
4. No committed `.env`, key file, trace log, meeting log, or audio recording is
   included in the release tree.
5. The maintainer email in `pyproject.toml` is intentional public package
   metadata.
6. Authentication-related names and placeholder values in source, tests, and
   documentation describe the security interface; they are not credentials.
7. Internal planning material under `docs/superpowers/` is excluded from the
   current public release tree and ignored by Git.

## Operational Guidance

- Inject authentication secrets and translation API tokens at runtime. Do not
  commit them.
- Keep `--auth-cookie-secure` enabled behind HTTPS.
- Treat subtitle trace logs as sensitive meeting data, even when context text is
  fingerprinted.
- Re-run these checks before every release tag.
