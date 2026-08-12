# Curo PDF Protector

Windows right-click "Protect with password" tool for Curo Financial Services.
Staff right-click a PDF in Explorer, search for a client (auto-fills DOB as
password), and get an AES-256 encrypted copy alongside the original. A
matching Outlook shortcut protects-and-attaches in one step.

Password recovery is guaranteed via RSA key escrow. No password is ever logged.

## Business launcher

Double-click **`PasswordProtect.cmd`** to open the same business protection flow
used by the Explorer entries. The launcher is PDF-only and refuses to protect
anything until machine health checks pass for settings, qpdf, clients.csv,
audit logging, and escrow.

1. Double-click `PasswordProtect.exe` (or `PasswordProtect.cmd`), or drag one or
   more PDFs onto it.
2. **One window lists every file.** Each row shows the client matched from the
   file name, the name the protected copy will get, and its status. Rows the
   tool could not match confidently say *Needs client* — select the row and
   search by name or file reference. **Protect all** stays disabled until every
   row has a client, because the password *is* that client's DOB (`DDMMYYYY`).
3. The run works through the files one at a time, updating each row to OK or
   FAILED as it goes. Cancel finishes the file in progress and stops; anything
   already protected keeps its escrow record. The window itself is the summary.
4. A protected copy lands in the same folder as the original as
   `name_protected.pdf`; the original is kept unless explicitly deleted by an
   admin workflow. Sites that want a different output name can set
   `output_name_template` in `settings.json` (tokens: `{OriginalName}`, `{Ext}`,
   `{ClientRef}`, `{Date}`, `{DateCompact}`, `{Seq}`); with the key absent the
   name is exactly `<name><output_suffix>.pdf` as before.
5. Every successful output has an audit event and an escrow sidecar with wrapped
   user and owner passwords.

The single-file Explorer right-click entry keeps its own one-file dialog, which
also allows a manually typed password where the client isn't in the list.

`qpdf.exe` is bundled in `bin\`. Requires Windows 10/11 and Windows
PowerShell 5.1 (built into Windows).

### If the window closes instantly / "crashes"

The launcher no longer disappears silently on failure:

- Any unexpected error is shown in a dialog **and** written to
  `PasswordProtect-error.log` (next to `PasswordProtect.cmd`). Send that file to
  whoever set this up.
- The console window now **stays open** (waits for a key) whenever the tool
  exits with an error, so you can read the message.
- Most common cause in managed environments: a red *"running scripts is disabled
  on this system"* message — that's a Group Policy blocking PowerShell scripts,
  which needs IT to allow the scripts (or to sign them); it can't be fixed from
  the tool itself.
- Keep the whole folder together — `PasswordProtect.cmd` needs `src\` and `bin\`
  beside it. The tool checks this on startup and names any missing file.

## Quick reference

| Task | Where |
|------|-------|
| Hand the tool to a teammate | `PasswordProtect.exe` (one portable file, built from `launcher\`; see `docs\ADMIN-SETUP.md`) |
| First-time setup on a machine | `setup.ps1`, or `PasswordProtect.exe --setup` |
| Roll out to the team | `docs\PILOT-CHECKLIST.md` |
| Check it works on a real Windows 11 PC | `docs\WIN11-ACCEPTANCE.md` (do this before handing it out) |
| Staff quick reference | `docs\CHEATSHEET.md` |
| Uninstall | `uninstall.ps1` |
| Protect a file | Right-click in Explorer → **Protect with password** |
| Protect + email | Right-click → **Protect and attach to new email** |
| Remove a password / restrictions | Right-click → **Remove password protection** (needs the password) |
| Re-key a protected file | `admin\Set-PdfPassword.ps1` (admin; only when the original is gone) |
| Update client list | `admin\Publish-Clients.ps1` (Practice Admin, weekly) |
| Recover a forgotten password | `admin\Recover-File.ps1` (with escrow USB) |
| Diagnose a broken install | `admin\Get-PDFProtectDiagnostics.ps1` |
| Weekly audit summary | `admin\Get-AuditSummary.ps1` |
| Rotate the escrow keypair | `admin\Rotate-EscrowKey.ps1` |

## What it does

- **PDF path:** real PDF AES-256 encryption via `qpdf`. Output opens in any
  viewer (Adobe, Edge, Preview) with the password.
- **Non-PDF files:** refused in v1 business mode — see `docs\RISK.md` #5 for why the
  scope is deliberately PDF-only.
- **Removing protection:** right-click -> **Remove password protection** produces an
  unprotected copy, given the password (`qpdf --decrypt` clears the password and
  every restriction in one pass). Audited; no escrow record, since there is no
  password to recover. Disable fleet-wide with `allow_password_removal: false`.
  There is deliberately no bypass - without the password qpdf cannot read the file.
- **Client picker** with type-ahead over `clients.csv`, published from the
  master client spreadsheet. Selecting a client auto-fills their DOB as
  password in `DDMMYYYY` format (no separators).
- **Manual resolution** for ambiguous/unmatched files by selecting the correct client from `clients.csv`.
- **Escrow** — each file's password is certificate-wrapped under the escrow
  public key and written to a per-file sidecar on
  `\\server\data\PDFProtect-Escrow\YYYY\MM\`. Admin recovers via
  `Recover-File.ps1` + the private PFX on the safe's USB.
- **Audit log** — JSONL at `%ProgramData%\CuroPDFProtect\audit.log`,
  7-year retention (Corps Act s.988A / RG 104).
- **Outlook integration** — Protect-and-attach / -reply / -forward via
  Outlook COM with a 5-second timeout and a desktop-drop fallback.

## Design principles

1. **Password never touches a managed string.** WPF `PasswordBox` →
   `SecureString` → BSTR → child process stdin → zeroed. Never argv, never
   logged, never in PowerShell history.
2. **Fail closed.** If the escrow share is unreachable, the tool refuses to
   protect. No protected file exists without its recovery record.
3. **Hard-to-break maintenance.** One machine-wide install path. One config
   file. One diagnostics script that produces the exact artefact a support
   ticket needs. Pester test matrix runs weekly on a pilot machine.
4. **No bespoke crypto.** `qpdf` does the PDF encryption; Windows certificate APIs wrap escrow secrets.

## Deployment

- Target: Windows 10 / 11, PowerShell 5.1 (ships with Windows — do NOT
  require PS 7).
- **Portable exe (easiest to hand out): `PasswordProtect.exe`.** One self-contained
  file (~7.6 MB) built from `launcher\`. It embeds this whole tool, extracts it to
  `%LOCALAPPDATA%\CuroPDFProtect\app\<payload-id>\` on first run, and runs the
  identical scripts — same escrow, same audit log, same PDF-only rule. Nothing to
  keep together and no console window. Build it with
  `dotnet publish launcher\CuroPdfProtect.Launcher -c Release -o publish`, or
  download the `PasswordProtect-portable-exe` artifact from a manual `windows-ci`
  run. Verbs: `--setup`, `--diagnose`, `--verify`, `--version`.
  *If staff see "running scripts is disabled on this system", the exe will not fix
  it* — that is Group Policy / AppLocker / WDAC, which overrides the
  `-ExecutionPolicy Bypass` the tool already passes. Run `--diagnose` to identify
  which, then sign the scripts or have IT allowlist them.
- **Setup: run `setup.ps1` once per machine** — guided, and either
  **Install** mode (admin; adds the right-click menu; installs to
  `C:\Program Files\CuroPDFProtect\`) or **Launcher** mode (no admin;
  drag-and-drop from the tool folder). See `docs\ADMIN-SETUP.md`.
- Dependencies: `qpdf.exe` + its runtime DLLs (Apache-2.0) bundled with pinned
  SHA-256 hashes; **all** binaries are verified at install, and a tampered or
  unpinned binary is refused.
- Shell integration (Install mode): `HKLM\Software\Classes\*\shell\...`
  (per-machine — new staff don't need per-user setup). On Windows 11 these verbs
  appear under **Show more options**; the optional `shellext\` package
  (`shellext\Install-ShellExt.ps1`) puts **Protect with password** in the MAIN
  right-click menu (needs a signed sparse MSIX — see `docs\ADMIN-SETUP.md`).
  `uninstall.ps1` removes the `HKLM` entries; `shellext\Uninstall-ShellExt.ps1`
  removes the modern-menu package.
- Small team? Follow `docs\PILOT-CHECKLIST.md`. GPO startup-script deployment
  and AD "ring" groups (`install.ps1 -SourcePath \\deploy$\...`) remain
  available for larger, IT-managed estates.

## Compliance boundary

Curo handles personal and financial information under the Privacy Act 1988
(APPs). AES-256 PDF encryption with DOB passwords is a defensible
document-level control in transit. Non-goal: regulated health (PHI) or
card (PCI) data — for those, use a vendor-managed solution. See
`docs/PROCEDURE.md` for the one-pager that slots into the Curo cyber
security policy.

## Repository map

```
README.md                       this file
config\
  settings.default.json         shipped defaults
docs\
  ARCHITECTURE.md               design detail
  RISK.md                       risk register
  DECISIONS.md                  decisions record (resolved)
  PROCEDURE.md                  policy one-pager
  RUNBOOK.md                    maintenance runbook
setup.ps1                       guided first-time setup (Install | Launcher)
src\
  Protect-File.ps1              Explorer entry point
  Protect-Folder.ps1            batch mode
  Protect.psm1                  core protect-one-file chain
  Prompt-Password.ps1           WPF dialog + SecureString
  Prompt-Drop.ps1               drag-drop window (standalone launcher)
  Show-CuroError.ps1            loud-failure logging + notification
  Find-Client.ps1               CSV lookup + picker data
  Invoke-QPdf.ps1               qpdf wrapper (password via @argfile)
  Write-Escrow.ps1              per-file sidecar writer (RSA-OAEP-SHA256)
  Send-OutlookAttachment.ps1    Outlook COM + fallback
  Config.psm1                   settings loader + validator + health
  Logging.psm1                  JSONL audit log + heartbeat
admin\
  Publish-Clients.ps1           atomic CSV publish from master XLSX
  Recover-File.ps1              escrow recovery
  Rotate-EscrowKey.ps1          recovery certificate rotation
  Get-PDFProtectDiagnostics.ps1 support-ticket artefact
  Get-AuditSummary.ps1          weekly report
install.ps1                     GPO-invoked installer
uninstall.ps1                   GPO-invoked uninstaller
tests\
  *.Tests.ps1                   Pester suites (all gate CI)
  fixtures\
    clients-sample.csv          sample client list used by tests
launcher\                       portable-exe wrapper around THIS tool (net48;
  CuroPdfProtect.Launcher\      embeds src\+bin\, extracts, runs PasswordProtect.ps1)
  Sign.targets                  optional Authenticode hook (no-op without a cert)
shellext\                       OPTIONAL Windows 11 main-menu right-click entry:
  CuroShellExt\                 IExplorerCommand COM server (native x64), plus a
  package\                      sparse MSIX for package identity. PDF-only verb;
                                Build-/Install-/Uninstall-ShellExt.ps1 manage it.
```

One CI workflow gates everything: `windows-ci.yml` runs the Pester suites, the
end-to-end protect/escrow/recovery proofs, both deployment modes, the portable
exe and the Windows 11 package, on `windows-latest`. Pushes to `main` also
publish the two deployable artifacts.
