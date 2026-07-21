# Curo PDF Protector — Maintenance Runbook

Day-to-day support playbook. Kept deliberately short — if a problem isn't
covered here, run `admin\Get-PDFProtectDiagnostics.ps1 -Copy` on the affected
machine and escalate to Brent or Ian with the report.

## 1. "It doesn't work" — first response

1. **If the window flashed and vanished**, or the tool "crashed", the first
   place to look is the per-user error log at
   `%LOCALAPPDATA%\CuroPDFProtect\error.log` (typically
   `C:\Users\<name>\AppData\Local\CuroPDFProtect\error.log`). The launcher also
   writes `PasswordProtect-error.log` next to `PasswordProtect.cmd`. Both are
   plain text, name the failing step, and never contain a password — ask the
   user to send whichever exists. A red *"running scripts is disabled on this
   system"* line means Group Policy is blocking the scripts (IT must allow or
   sign them); it is not a tool fault.
2. For anything else, ask the user to run
   `admin\Get-PDFProtectDiagnostics.ps1 -Copy` on the affected machine and paste
   the report.
3. Review the report top-to-bottom. Most problems present as one of:
   - `Config load: FAIL` → `setup.ps1` was never run on this machine, or
     `settings.json` was hand-edited. Re-run `setup.ps1` (it is idempotent and
     re-validates the config), or `install.ps1` for an IT-managed estate.
   - `qpdf: MISSING` or `binary integrity: FAIL` → the `bin\` folder was
     separated from the tool or a file was replaced. Restore `bin\` from the
     original source alongside `src\`; the SHA-256 pins in `bin\HASHES.txt`
     must match.
   - `Client CSV primary: UNREACHABLE` → network or share permission
     issue. Also check the audit log's last `error_code` —
     `CSV_OFFLINE` or `ESCROW_OFFLINE` point to the shared location.
   - `Escrow share: UNREACHABLE` → tool is correctly refusing to protect.
     Restore access to the escrow location. Once reachable, retry the operation.
   - `HKLM context entry: MISSING` (Install mode only) → registry didn't
     write. Re-run `setup.ps1 -Mode Install` (or `install.ps1`) as
     Administrator.

## 2. "Client says password doesn't work"

1. Open `admin\Get-AuditSummary.ps1 -Days 3` to confirm the file was
   protected successfully today.
2. Grep the audit log for the filename or client ref. Check the
   `password_source` field: `dob` means the client's DOB from the CSV was
   used; `manual` means a staff-typed password was used.
3. If `password_source=dob`, confirm the DOB in the CSV matches what the
   client believes their DOB to be. Send the client the standard
   boilerplate wording again (see `docs/PROCEDURE.md`).
4. If still broken, recover via step 3.

## 3. "Client can't open, needs password recovery"

*Requires the office-safe USB containing the escrow private key (`.pfx`) **and**
the password that protects that `.pfx`. Brent or Ian only.*

1. Plug the USB into an admin workstation.
2. Open PowerShell and run (adjust the drive letter for the USB):

   ```powershell
   cd 'C:\Program Files\CuroPDFProtect\admin'
   .\Recover-File.ps1 -PrivateKeyPath E:\curo-escrow.pfx `
                      -OutputPath '\\server\clients\SoA_Smith_protected.pdf'
   ```
   You are prompted for the `.pfx` password (or pass it non-interactively with
   `-PfxPassword (Read-Host -AsSecureString)`). Use `-ClientRef C-00421` or
   `-SourceName 'SoA_Smith.pdf'` instead of `-OutputPath` if you don't have the
   protected file to hand.
3. Password is placed on the clipboard. Send to the client via your usual
   secure channel (SMS, phone — NOT the same email channel the file went
   out on).
4. **Clear the clipboard** afterwards (`Set-Clipboard -Value ''`).
5. The recovery is audit-logged on the admin workstation automatically.
6. If recovery reports a **fingerprint mismatch**, the `.pfx` on the USB is not
   the key this file was escrowed under — try the other (older) key copy. Files
   escrowed under a rotated key are only recoverable with that key's `.pfx`.

## 4. CSV out of date

Run on the Practice Administrator's machine:

```powershell
cd 'C:\Program Files\CuroPDFProtect\admin'
.\Publish-Clients.ps1 -Source '\\server\shared\Master\Clients.xlsx'
```

A dry-run (`-DryRun`) is available for testing before overwriting the live
CSV. Any row with a malformed DOB is skipped and reported. Runs in
seconds; safe to run ad-hoc.

## 5. Rolling back a bad deploy

Keep the previous version's tool folder alongside the current one (small
teams: the whole clone; IT-managed estates: the previous payload on the
deploy share).

- **Small team (setup.ps1 / launcher):** on each affected machine, re-run
  `setup.ps1` from the previous version's folder, or point the launcher /
  right-click at it. `settings.json` and the audit log are untouched by a
  rollback.
- **IT-managed (GPO):** point the deploy share back at the previous payload
  (swap `bin\`, `src\`, `admin\`, `config\`), then `gpupdate /force` and reboot
  a pilot machine.

Either way, verify with `Get-PDFProtectDiagnostics.ps1` before rolling wider.

## 6. Rotating the escrow keypair

Annually, or immediately on suspected compromise or departure of anyone
with USB access.

1. Generate a replacement keypair: `admin\Rotate-EscrowKey.ps1
   -NewPrivateKeyPath E:\curo-escrow-YYYYMMDD.key`.
2. The old USB is **retained** in the safe (files protected under the old
   key can only be recovered with the old key — forever).
3. Make the off-site second copy of the new USB.
4. Verify by protecting a fresh test file and recovering it with the new
   key.
5. Update the asset register with the new pubkey fingerprint.

## 7. Onboarding a new staff member

- **Small team:** run `setup.ps1` once on the new machine (see
  `docs\ADMIN-SETUP.md`). Install mode adds the right-click menu machine-wide;
  Launcher mode needs no admin. New starters on a machine that already has
  Install mode need nothing — the menu is per-machine, not per-user.
- **IT-managed (GPO):** the tool lands at first reboot after the machine joins
  AD; no per-user step.

Verify either way:

1. Right-click a PDF → confirm "Protect with password" appears (Install mode),
   or double-click `PasswordProtect.cmd` (Launcher mode).
2. Run `admin\Get-PDFProtectDiagnostics.ps1`.

## 8. Decommissioning a machine

1. `uninstall.ps1 -PurgeAuditLog` — only after the machine's audit log
   has been copied to the central audit archive on the file server.
2. Back up the audit archive; it is retained for 7 years from the date of
   the last audit entry.

## 9. Weekly rhythm

| Day | Task | Owner | Time |
|-----|------|-------|------|
| Mon | Run `Publish-Clients.ps1` | Practice Admin | ~5 min |
| Mon | Run `Get-AuditSummary.ps1 -Days 7` | Brent or Ian | ~5 min |
| Mon | Review any non-zero `error_code` counts | Brent or Ian | ~5 min |
| Bi-annual | Test escrow recovery end-to-end | Ian | ~15 min |
| Annual  | Rotate escrow keypair | Brent | ~30 min |
| Annual  | Review procedure doc against current ASIC guidance | Brent | ~30 min |

## 10. Known limitations

- Tool does not run offline (by design — no protected file without its
  escrow record).
- "New Outlook" (Monarch) is not supported for the in-tool attach flow.
  Users on New Outlook get the desktop-drop fallback.
- qpdf cannot password-protect PDFs that carry XFA forms embedded by older
  Adobe LiveCycle workflows. These are rare in financial advice documents.
- Very large files (>2 GB) are supported but may take minutes to encrypt;
  the success dialog appears only on completion.
