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

**Decision:** `<stem>_protected.pdf` created alongside the
original. Default: do NOT overwrite existing `_protected` files, do NOT
delete the original. Both are opt-in checkboxes in the prompt.

## 7. Manual-password policy

**Decision:** Minimum 10 characters, at least 3 of 4 character classes
(lower / upper / digit / symbol). DOB-derived passwords are exempt from
this check (always 8 digits by convention).

## 8. Dependencies

**Decision:** Bundle `qpdf.exe` (Apache-2.0) with the
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

---

# Rollout-hardening decisions (2026-07-21)

Added while preparing the tool for wider team rollout. Each supersedes the
matching part of the entries above where they differ.

## 18. Guided setup + single config system

**Decision:** A fresh machine is set up with one guided, idempotent
`setup.ps1` in either **Install** (admin, right-click menus) or **Launcher**
(no admin, drag-and-drop) mode. Config is resolved by one system
(`Config.psm1` / `Get-CuroConfigPath`): `$env:CURO_SETTINGS_PATH` →
`%ProgramData%\CuroPDFProtect\settings.json` → `<tool root>\config\settings.json`.
`settings.default.json` is a template only. This replaces the previous
"install.ps1 + a hand-staged settings.json only" story so the tool works from a
fresh clone without recreating an AD/GPO/file-server environment first.
Supersedes the deployment assumptions in entry 8 for small teams; GPO stays
available for larger estates (see `docs\PILOT-CHECKLIST.md`).

## 19. Escrow wrapping upgraded to OAEP-SHA256

**Decision:** New escrow sidecars wrap passwords with RSA-OAEP-**SHA256** (via
the certificate's CNG key), recording `key_wrap_algorithm=rsa-oaep-sha256-cert`.
`Recover-File.ps1` chooses padding from the recorded algorithm, so legacy
SHA-1 and schema-1 sidecars remain recoverable. Corrects the earlier code,
which wrapped with SHA-1 while the docs claimed SHA-256. Also fixed a latent
bug where recovery opened the private `.pfx` with an empty password
(`-PfxPassword` is now required/prompted).

## 20. qpdf password channel

**Decision:** Passwords reach qpdf via a locked-down, BOM-less `@argfile`
(temp file, shredded immediately), not the process command line. A UTF-8 BOM
on the argfile made qpdf misparse `--encrypt` and silently broke encryption on
the real Windows binary; this is the channel that actually works.

## 21. Audit-log concurrency and folder ACLs

**Decision:** Audit appends are serialised with a machine-wide named mutex
(plus IOException retry) so a folder batch and a right-click running at once no
longer collide and crash. `%ProgramData%\CuroPDFProtect` is made read-only for
standard Users (protecting `settings.json` and `escrow.cer`), while `cache\`
and `audit.log` stay writable. **Open item:** tightening the audit log to
*append-only* (tamper-evident) for standard users is deferred — it needs the
Framework-only append-only `FileStream` path and more testing; low priority for
a small trusted team.

## 22. Binary supply-chain verification

**Decision:** `install.ps1` verifies **all** pinned binaries bidirectionally
(every pin present and matching; every `.exe`/`.dll` in `bin\` pinned) and
refuses a tampered or unpinned binary; a missing `HASHES.txt` is a hard
refusal. `Test-CuroHealth` re-checks integrity at runtime. Replaces the prior
behaviour that verified only `qpdf.exe`.

## 23. DOB-as-password - **sign-off required at rollout**

**Flag, not a change.** The password is the client DOB (`DDMMYYYY`, ~30k
plausible values, often discoverable), and the covering-email boilerplate
discloses the format. This is an accepted trade-off (entry 3 / `PROCEDURE.md`),
but before widening the audience it should get an explicit, dated **director
sign-off**, with the option to raise the manual-password minimum from 10 to 12.

## 24. Manual-fallback vs launcher behaviour - **to reconcile**

**Flag.** Entry 1 says the manual-password fallback is "never a hard block",
but the standalone launcher (`PasswordProtect.ps1`) invokes the picker with
`-RequireClientDob`, which *does* require a client/DOB per file. Brent/Ian to
decide the intended behaviour for the launcher and align the code or entry 1.

---

# Two implementations on main (2026-07-27)

## 25. The `app\` .NET prototype - **RESOLVED 2026-08-11: ported, then removed**

**Status: closed - see "The decision" below.** The `claude/password-protected-docs-e09cmy`
branch was merged into `main`, adding a second, independent implementation under
`app\`: a .NET 8 / WPF desktop app (qpdf for PDF, from-scratch MS-OFFCRYPTO for
Office, 7-Zip fallback) with its own CI (`app-ci.yml`). It was written in June,
**before** the PDF-only rework and before the rollout hardening in entries 18-22.
It was merged to preserve the work, not to ship it.

**The PowerShell tool at the repo root remains the supported product.** Nothing in
`docs\ADMIN-SETUP.md`, `docs\PILOT-CHECKLIST.md` or `docs\RUNBOOK.md` changes.

**Why the app could not be used on client files** (the findings that drove the decision;
file/line evidence in the commit that added this entry):

1. **No escrow, no audit log.** The protect path writes no sidecar and logs no event
   (`Batch\BatchRunner.cs`, `Engines\QpdfProtector.cs`). This is **unconditional** -
   the default `<name>_protected.pdf` path is as affected as any other, so every file
   the app protects is already unrecoverable (`admin\Recover-File.ps1` has no sidecar
   to read) with no record that the operation occurred. Contradicts entry 5
   (fail-closed escrow) and entry 11 (7-year audit).
   *Aggravating factor:* with *Overwrite in place* the plaintext original is replaced
   too, so a forgotten password destroys the only readable copy. That option is at
   least opt-in - off by default and behind an explicit "cannot be undone" confirm
   (`AppServices.cs`, `MainWindow.xaml.cs`) - but neither gate is an escrow gate,
   because there is no escrow code to fail closed on.
2. **Out of PDF-only scope.** Office documents are encrypted by hand-rolled
   MS-OFFCRYPTO code that needs no external binary and is wired into Explorer for
   `.docx/.xlsx/.pptx`. Entry 8 / `RISK.md` #5 scope v1 to PDF deliberately.
3. **Unauthenticated decryption.** `OfficeCrypto.Encrypt` writes the `dataIntegrity`
   HMAC; `TryDecrypt` never verifies it, so tampering or corruption is undetected and
   *Change*/*Remove password* can emit a corrupted document as a success.
4. **Crypto is unproven.** The Office tests are self-consistency only (synthetic zip,
   encrypt-then-decrypt with the same code). No known-answer vector, no Office-produced
   fixture, no independent cross-check.
5. **Passwords on the command line.** Every engine passes the password as a child
   process argument, reversing the `@argfile` decision in entry 20.
6. **Weaker supply chain.** NuGet restores unlocked with audit warnings non-blocking
   (`OpenMcdf 2.3.1` carries two advisories; the fix is a 3.x API port, not a bump).
   Entry 22 holds the PowerShell half to bidirectional SHA-256 pinning.
7. **Duplicate Explorer verb.** `ContextMenuRegistrar.cs` registers a per-user entry
   labelled *"Protect with password"* - character-identical to the `HKLM` verb from
   `install.ps1`. They are additive, so on a machine with both a staff member sees two
   indistinguishable entries and only one escrows. `uninstall.ps1` leaves the app's
   entry behind, and `Get-PDFProtectDiagnostics.ps1` does not probe for it.
8. **Shared `bin\` coupling.** The app embeds the repo-root `bin\` as its payload, so
   the PowerShell tool's binary curation silently reshapes it. `7z.exe` was removed
   when the flow went PDF-only, so the app's 7-Zip engine is **dead in any build from
   `main`** while still being the route for every non-PDF, non-Office file.

**The decision (Brent).** *Fold the good parts in, then remove.* Taken 2026-08-11:

1. The batch queue with per-file status, and configurable output naming, were ported
   into the supported tool - see entry 26 - where they drive the audited core, so
   escrow, the audit log, PDF-only and fail-closed all apply.
2. `app\` and `app-ci.yml` were then **deleted from `main`**. `Sign.targets`, the one
   file the supported launcher imported from that tree, moved to `launcher\`.
3. Office encryption, password add/change/remove and the dead 7-Zip path were NOT
   ported - reasons in entry 26. Items 3-8 above therefore never needed fixing.

History is preserved on branch `claude/password-protected-docs-e09cmy` and in merge
commit `878269b`. `docs\RISK.md` #13 records the one residual: a PC where someone ran
the prototype's `--register-context-menu` still carries a per-user Explorer verb that
does not escrow, and `uninstall.ps1` has never touched `HKCU`. Removing the source does
not remove that key - the Windows 11 acceptance pass now includes deleting it.

---

# Batch queue window and naming templates (2026-08-11)

## 26. Fold the prototype's batch UI into the supported tool

**Decided: port, do not keep two products.** The `app\` prototype's genuinely
useful parts - a queue listing every file with per-file status, and configurable
output naming - are now in the supported PowerShell tool (`src\Prompt-Batch.ps1`,
`src\BatchQueue.psm1`, `src\Naming.psm1`). This resolves entry 25: see entry 27.

**What was NOT ported, and why.**

- **Office encryption.** Out of scope per `RISK.md` #5, and the prototype's
  implementation writes no `\x06DataSpaces` storage and never verifies the
  `dataIntegrity` HMAC it writes, so a tampered file decrypts silently. It was
  also only ever tested against itself - no known-answer vector, no
  Office-produced fixture. Not fit to go near a client file.
- **Add / change / remove password.** Removing protection from a client file
  leaves its escrow sidecar describing a file that no longer needs it, with no
  audit trail of the removal. If this is ever wanted it needs its own audit
  event and a fresh escrow record, not a reused protect path.
- **The prototype's 7-Zip fallback.** No `7z.exe` ships (removed when the flow
  went PDF-only), so that path was dead in every build from `main`.

**Design calls worth recording.**

1. **Rows are replaced, never mutated.** A `[pscustomobject]` raises no
   property-change notification, so assigning `$row.StatusText` updates nothing
   on screen and reports no error at all. The window replaces the row in an
   `ObservableCollection` instead. `tests\Xaml.Tests.ps1` pins every
   `{Binding}` path against a real row, because a stale or misspelled path is a
   silently blank cell, not an exception.
2. **The protect core stays on the UI thread**, driven by two chained
   `Dispatcher.BeginInvoke` items per file (mark row Working, then run). Render
   and Input priorities outrank Background, so the row repaints and a Cancel
   click lands between files. A worker runspace was rejected: the core holds a
   machine-wide named mutex for its audit append and disposes SecureStrings, and
   marshalling progress back would double the threading models the audited path
   runs under. Cost accepted: the window is frozen during each file, and says so.
3. **Cancel finishes the current file.** Killing it mid-escrow could leave a
   protected file with no recovery record - the one thing the fail-closed design
   exists to prevent. Completed files are never rolled back; their escrow and
   audit rows are correct records of what happened.
4. **No Outlook checkbox on the batch path.** The old drag-drop flow never
   offered it, and one ticked box on a ten-file batch means ten compose windows.
   Protect-and-email stays a single-file right-click action.
5. **Exit code stays 0** for any run the user saw through, failures included -
   the window showed each one per row. Non-zero remains reserved for crashes and
   health refusals, because `PasswordProtect.cmd` pauses with a diagnostic block
   on any non-zero exit.
6. **`output_name_template` is optional.** `Assert-ConfigField` throws on a
   missing key, so making it required would invalidate every `settings.json`
   already deployed and tell the whole team "not set up" after an update. With
   the key absent the name is byte-identical to the historical
   `<stem><output_suffix><ext>`; `tests\Naming.Tests.ps1` and
   `tests\ProtectCore.Tests.ps1` both pin that.
7. **The single-file right-click dialog is unchanged.** `Prompt-Password.ps1`
   still serves `Protect-File.ps1` and the folder batch, including the manual
   password path that entry 1 requires. Entry 24 (`-RequireClientDob`
   divergence between the two paths) is still open and is not resolved by this.

---

# Client auto-matching (2026-08-12)

## 27. A loose file-name match is a suggestion, never a pre-filled client

**Found by `tests\Simulate-UserJourney.ps1` on its first run** (CI #68), not by
review: the transcript showed `quarterly summary.pdf` sitting in the batch queue
as **Ready**, with **Mary O'Brien** as its client.

`Find-ClientForFileName` grades matches. *Strong* is a `file_ref`, a whole name,
or 2+ name tokens found in the file name. *Weak* is a single name token of 4+
characters, which exists so `Smith_report.pdf` still proposes every Smith. The
test is a plain substring over the squashed file name, so an ordinary English
word can contain a client's given name: `"quarterlysummary"` contains `"mary"`.

Both consumers then auto-selected a **lone candidate regardless of strength** -
`BatchQueue.psm1` marked the row `Ready` with the client pre-filled, and
`Prompt-Password.ps1` pre-selected it in the single-file dialog. The batch case
is the dangerous one: the row looks confident, the "Protect all" gate opens, and
a staff member working through ten files encrypts an unrelated document with the
wrong client's date of birth - unopenable by the intended recipient, and
misattributed in both the audit row and the escrow record. Nothing downstream
can catch it, because every layer faithfully records the client it was given.

**Decision.** Auto-assignment requires a *strong* match.

- `Find-ClientForFileName` gains `-StrongOnly`. Default output is unchanged, so
  weak candidates are still offered.
- `New-BatchRow` qualifies with `-StrongOnly` before assigning, and only when
  there is exactly one candidate (so the extra pass costs nothing otherwise). A
  lone weak match leaves the row `NeedsClient` with `CandidateCount = 1`.
- `Prompt-Batch.ps1` pre-loads the row's candidates into the results list, so
  confirming a suggestion is one click rather than retyping, and its hint says
  "check it is right for this file" instead of "no client matched".
- `Prompt-Password.ps1` selects the initial match only when it is strong.

Deliberately **not** done: raising the weak-token length threshold (it would
have to reach 6+ to exclude `mary`, which discards real surnames like `Patel`),
or word-boundary matching (still fuzzy, and it would stop matching
`SmithJohnSOA.pdf`). Offering rather than assuming is the honest fix - the tool
cannot know, so it asks.

Pinned by `tests\FindClient.Tests.ps1` (offered but not strong),
`tests\BatchQueue.Tests.ps1` (no auto-assign on a lone weak match), and the
journey scene that found it. `docs\CHEATSHEET.md` now tells staff the tool only
fills in a client when the name clearly identifies one.

---

# Removing protection (2026-08-12)

## 28. The tool removes passwords and restrictions, with the password, audited

**Requested by Brent.** Until now the tool could only ADD protection. Staff
routinely need the reverse: filing a document, or a client returns a protected
PDF. `qpdf --decrypt` clears the open password AND every restriction (printing,
copying, editing) in one pass, so one action covers "remove the password" and
"remove the security".

**The password is required. There is no bypass and none will be added.** Without
it qpdf cannot read the file. A cracking or restriction-stripping path would be
indefensible in a tool whose purpose is protecting client documents, and it is
not what was asked for. For a file this tool produced the password IS the client
DOB, so the existing client picker supplies it; a typed password covers PDFs from
providers and clients.

**Decisions inside this one:**

1. **No escrow record for an unprotected copy.** There is no password to
   recover. Writing one would put a recovery entry against a file that needs
   none, and would imply the copy is protected.
2. **Therefore the audit row is the only trace, and is written on failure too.**
   An unprotected copy of a client document is precisely what a compliance
   reviewer would look for. `op=unprotect` carries the client reference, the
   password source, and both file hashes.
3. **The protected original is never deleted.** Staff asked to remove a
   password, not to destroy the protected copy - and the escrow record covering
   that original must keep pointing at a file that exists.
4. **`_protected` is stripped before `_unprotected` is added**, so
   `Statement_protected.pdf` yields `Statement_unprotected.pdf` rather than
   `Statement_protected_unprotected.pdf`, which would be actively misleading on
   a file whose point is that it is not protected.
5. **The success dialog always shows**, even where `show_success_dialog` is off
   for protecting. The user has just created an unencrypted copy of a client
   document and is told plainly where it is.
6. **No complexity check on the supplied password.** In `-Purpose Unprotect` the
   password is whatever already opens the file; running
   `Test-ManualComplexity` would reject the 8-digit DOB this tool itself
   applied. The confirm box is hidden for the same reason - there is nothing to
   mistype twice.
7. **`allow_password_removal` (default true, absent means true)** lets a site
   switch the whole capability off fleet-wide without redeploying. The shim
   refuses before prompting, so nobody types a password for nothing.

**Not built, deliberately:** changing a password in place. It needs a NEW escrow
record for the new password or recovery silently returns one that no longer
opens the file - a worse failure than not having the feature. Say the word if
it is wanted and it will be built with that record.

**Residual risk to accept or restrict.** Any staff member can now create an
unencrypted copy of a client document. That is the point of the feature, it is
audited, and the copy carries no more risk than the original unprotected file
they already had - but if the firm would rather it were an admin-only act, set
`allow_password_removal` to false and use the escrow recovery path instead.

---

# Changing a password (2026-08-12)

## 29. Password change is admin-only, in place, and escrows before it commits

Entry 28 deferred this; requested straight after, so built.

**Admin-only (`admin\Set-PdfPassword.ps1`), not a right-click verb.** It is
rarely the right tool: if the unprotected original still exists - and this tool
never deletes originals - the simpler fix is to correct the client list and
protect it again. Re-keying is for when the original is gone. Putting a
consequential in-place rewrite of a client file behind an admin script also
keeps the Explorer menu at four entries.

1. **One qpdf pass, no plaintext on disk.** `--password` applies to the input
   and `--encrypt` to the output, so the file is read encrypted and written
   encrypted in a single invocation. The obvious alternative - decrypt to a temp
   file, then encrypt it - leaves an unprotected copy of a client document in
   `%TEMP%` for the duration. The removed prototype did exactly that.
2. **In place, not a second file.** Two protected copies of one document under
   different passwords is a compliance trap: nobody can later say which one the
   client was sent.
3. **Escrow before commit, and roll back.** This is a STRICTER order than the
   protect path. The record for the new password is written while the original is
   still intact; only then is the new file swapped in. If escrow is unreachable
   the original is restored byte-for-byte and the client's copy still opens. The
   protect path cannot do this - there is no earlier file to fall back to - so it
   deletes its output instead. Where the safer order is available it is used.
4. **The OLD escrow record is kept.** It truthfully records a file that existed
   and was sent. Deleting compliance history to tidy up would be the wrong
   trade; recovery keys on content hash, so the stale record simply stops
   matching anything on disk.
5. **The current password is required**, as in entry 28. If it is unknown and
   the tool produced the file, recover it first with `admin\Recover-File.ps1`.

**Stated plainly to the operator, twice:** a copy already sent to the client
keeps opening with the OLD password. Changing it here does not reach out and
change theirs.
