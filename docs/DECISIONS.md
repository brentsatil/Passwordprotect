# Decisions Record (resolved)

Captured from the design conversation between Brent, Ian, and the build
agent. Source of truth for *why the implementation looks the way it does*.
Changes to any of these require a new entry with a date and sign-off.

## 1. Client identification

**Decision:** Type-ahead picker over `clients.csv`. Selecting a client
auto-fills DOB as the password. Free-form manual fallback when the client
isn't in the CSV — never a hard block.

**Rejected alternatives:** filename parsing (brittle — depends on an
adviser convention that won't hold); folder parsing (ties the tool to a
folder structure that will change).

## 2. CSV schema and location

**Decision:** `client_name,dob,file_ref`, UTF-8 with BOM, at
`\\server\shared\PDFProtect\clients.csv`. Published weekly by the Practice
Administrator via `admin\Publish-Clients.ps1` (atomic write; validates DOB
at publish time; safe to re-run). Stale-warn at 8 days; hard-fail at 21
days. Local 48-hour cache used when the share is briefly unreachable.

## 3. Password format

**Decision:** `DDMMYYYY`, zero-padded, no separators. Canonical example
`12031970`. Standard client-facing boilerplate in the covering email.

## 4. Escrow

**Decision:** RSA-4096 keypair. Private key on a USB in the office safe;
second copy at Ian's home safe. One JSON sidecar per protected file at
`\\server\data\PDFProtect-Escrow\YYYY\MM\<output_sha256>.escrow.json`.
Each sidecar records the pubkey fingerprint so recovery continues to work
across key rotations (old private keys retained indefinitely).

Read access on the escrow share: Brent and Ian only. Write access:
SYSTEM + domain users (tool writes). Backed up as part of the file-server
nightly backup with 7-year retention.

**Rejected alternative:** single append-only `escrow.log`. Multi-machine
concurrent writes interleave on SMB; per-file sidecars eliminate the
problem. Trade-off accepted: file-count grows linearly (≈10k/year), easy
to glob with the recovery tool.

## 5. Escrow outage behaviour

**Decision:** **Refuse-closed.** If the escrow share is unreachable, the
tool refuses to protect. No protected file ever exists without its
recovery record. 5-minute server outage stops client-facing work; this
trade-off is accepted because an unrecoverable protected file is worse
than 5 minutes of waiting.

## 6. Output and original file

**Decision:** `<stem>_protected.pdf` (or `.7z`) created alongside the
original. Default: do NOT overwrite existing `_protected` files, do NOT
delete the original. Both are opt-in checkboxes in the prompt.

## 7. Manual-password policy

**Decision:** Minimum 10 characters, at least 3 of 4 character classes
(lower / upper / digit / symbol). DOB-derived passwords are exempt from
this check (always 8 digits by convention).

## 8. Dependencies

**Decision:** Bundle `qpdf.exe` (Apache-2.0) and `7z.exe` (LGPL) with the
installer. Pin SHA-256 hashes in `bin\HASHES.txt`; installer refuses to
proceed on mismatch. Quarterly review for CVE updates.

## 9. Deployment

**Decision:** GPO startup script per-machine from
`\\server\deploy$\CuroPDFProtect\`. `HKLM` context-menu entries (not
`HKCU` — new starters don't need a per-user setup). Staged rollout via AD
security groups: Ring0 (3 machines, 1 week) → Ring1 (5 machines, 1 week)
→ Ring2 (rest).

Ring rollback: swap payload on the deploy share with the previous
version's, force `gpupdate`, reboot pilot machines.

## 10. Outlook integration

**Decision:** Included in v1, full. Compose-new, reply-to-selection,
forward-selection modes. 5-second COM timeout. "New Outlook" (Monarch)
triggers the desktop-drop fallback automatically (classic COM not
available). Outlook-attach failures do not block the protect operation.

## 11. Audit log

**Decision:** JSONL at `%ProgramData%\CuroPDFProtect\audit.log`. UTF-8
without BOM. 7-year retention (Corps Act s.988A / ASIC RG 104). Weekly
summary via `admin\Get-AuditSummary.ps1`. Password fields defensively
redacted on any future log format change (none today record them).

## 12. Diagnostics

**Decision:** One script — `admin\Get-PDFProtectDiagnostics.ps1 -Copy` —
produces the single artefact a support ticket needs. Covers config,
dependency hashes, CSV and escrow reachability, PowerShell/OS version,
last 5 audit entries, AD group membership, and context-menu registration
state.

## 13. Testing

**Decision:** Pester tests for DOB normalisation, config validation, and
escrow round-trip. A weekly Pester run on one pilot machine flags
regressions. End-to-end smoke test (protect → recover a known fixture)
runs as part of the weekly check.

## 14. Code signing

**Decision:** Procure a Sectigo or DigiCert cert (~AUD 300/year). Until
then, scripts run with `-ExecutionPolicy Bypass` from the GPO-invoked
installer. First renewal budget-approved now.

## 15. EDR / AV

**Decision:** Whitelist the signed binary hashes with Curo's EDR vendor
before Ring0 rollout. Budget one week for submission and confirmation.

## 16. Machines outside AD

**Action item:** headcount any non-domain-joined machines (home PCs,
contractor laptops). Those run a one-off `install.ps1` manually.

## 17. Regulated data

**Decision:** Curo is not in the PHI/PCI camp. The tool is defensible for
the APP-regulated personal-and-financial information it handles, subject
to the procedure in `docs/PROCEDURE.md`. For anything regulated at a
higher bar (e.g. client legal records), escalate and use vendor-managed
encryption.
