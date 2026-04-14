# Curo PDF Protector

Windows right-click "Protect with password" tool for Curo Financial Services.
Staff right-click a PDF in Explorer, search for a client (auto-fills DOB as
password), and get an AES-256 encrypted copy alongside the original. A
matching Outlook shortcut protects-and-attaches in one step.

Password recovery is guaranteed via RSA key escrow. No password is ever logged.

## Quick reference

| Task | Where |
|------|-------|
| Install on a machine | `install.ps1` (GPO startup script runs this) |
| Uninstall | `uninstall.ps1` |
| Protect a file | Right-click in Explorer → **Protect with password** |
| Protect + email | Right-click → **Protect and attach to new email** |
| Update client list | `admin\Publish-Clients.ps1` (Practice Admin, weekly) |
| Recover a forgotten password | `admin\Recover-File.ps1` (with escrow USB) |
| Diagnose a broken install | `admin\Get-PDFProtectDiagnostics.ps1` |
| Weekly audit summary | `admin\Get-AuditSummary.ps1` |
| Rotate the escrow keypair | `admin\Rotate-EscrowKey.ps1` |

## What it does

- **PDF path:** real PDF AES-256 encryption via `qpdf`. Output opens in any
  viewer (Adobe, Edge, Preview) with the password.
- **Non-PDF path:** AES-256 `.7z` archive with encrypted headers via `7z`.
- **Client picker** with type-ahead over `clients.csv`, published from the
  master client spreadsheet. Selecting a client auto-fills their DOB as
  password in `DDMMYYYY` format (no separators).
- **Manual fallback** when the client isn't in the CSV — never a hard block.
- **Escrow** — each file's password is RSA-OAEP-wrapped under the escrow
  public key and written to a per-file sidecar on
  `\\server\data\PDFProtect-Escrow\YYYY\MM\`. Admin recovers via
  `Recover-File.ps1` + the private key on the safe's USB.
- **Audit log** — JSONL at `%ProgramData%\PasswordProtect\audit.log`,
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
4. **No bespoke crypto.** `qpdf` and `7z` do the encryption; this tool is
   the glue.

## Deployment

- Target: Windows 10 / 11, PowerShell 5.1 (ships with Windows — do NOT
  require PS 7).
- Channel: GPO startup script per-machine. Install path
  `C:\Program Files\CuroPDFProtect\`.
- Dependencies: `qpdf.exe` (Apache-2.0) and `7z.exe` (LGPL) bundled with
  pinned SHA-256 hashes, verified at install.
- Shell integration: `HKLM\Software\Classes\*\shell\CuroProtectWithPassword`
  (per-machine — new staff don't need per-user setup).
- Staged rollout via AD security groups: `CuroPDFProtect-Ring0` (3 machines,
  1 week) → `-Ring1` (5, 1 week) → `-Ring2` (everyone).

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
src\
  Protect-File.ps1              Explorer entry point
  Protect-Folder.ps1            batch mode
  Prompt-Password.ps1           WPF dialog + SecureString
  Find-Client.ps1               CSV lookup + picker data
  Invoke-QPdf.ps1               qpdf wrapper (stdin password)
  Invoke-SevenZip.ps1           7z wrapper (stdin password)
  Write-Escrow.ps1              per-file sidecar writer
  Write-AuditLog.ps1            JSONL audit log
  Send-OutlookAttachment.ps1    Outlook COM + fallback
  Config.psm1                   settings.json loader + validator
  Logging.psm1                  heartbeat + structured errors
admin\
  Publish-Clients.ps1           atomic CSV publish from master XLSX
  Recover-File.ps1              escrow recovery
  Rotate-EscrowKey.ps1          keypair rotation
  Get-PDFProtectDiagnostics.ps1 support-ticket artefact
  Get-AuditSummary.ps1          weekly report
install.ps1                     GPO-invoked installer
uninstall.ps1                   GPO-invoked uninstaller
tests\
  *.Tests.ps1                   Pester smoke + integration
  fixtures\                     sample PDFs, docx, long-path, etc.
```
