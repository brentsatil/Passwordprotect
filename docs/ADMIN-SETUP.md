# Admin Setup - fresh machine to working tool

This is the practical "how do I get it running" guide. Pick **one** of the two
modes below. Both end with a health check that tells you, in plain language,
whether anything still needs doing.

You need two shared locations that every teammate's PC can reach:

1. **Client list** - a `clients.csv` published from your master client
   spreadsheet. It holds `client_name, dob, file_ref`.
2. **Escrow folder** - where password-recovery records are written. Back this
   up; it is how a forgotten password is recovered.

Each location can be a network share (`\\server\share\...`), a **synced
OneDrive/SharePoint folder** (use the local synced path, e.g.
`C:\Users\you\OneDrive - Curo\PDFProtect`), or a plain local/USB path. If you
use a synced folder, make sure it is actually synced on every PC (not
"online-only"), or the tool will report the client list or escrow folder as
unreachable.

---

## Mode A - Launcher (no admin rights needed)

Best for a small team where you don't want to touch each machine as an
administrator. Staff protect PDFs by dragging them onto a launcher.

1. Copy the whole tool folder somewhere on the PC (or onto a shared folder each
   PC can run from) - keep `PasswordProtect.cmd`, `src\`, `bin\`, `config\`,
   `admin\` together.
2. Open PowerShell in that folder and run:

   ```powershell
   .\setup.ps1 -Mode Launcher `
       -ClientListPath 'C:\Users\you\OneDrive - Curo\PDFProtect\clients.csv' `
       -EscrowDir      'C:\Users\you\OneDrive - Curo\PDFProtect-Escrow' `
       -ClientSource   'C:\Users\you\OneDrive - Curo\Master\Clients.xlsx' `
       -PfxPath        'D:\curo-escrow.pfx'
   ```

   You'll be asked to choose a password for the escrow key (`.pfx`). **Write it
   down and keep it with the USB** - see "Key custody" below.
3. When it prints `Setup complete`, staff use the tool by **dragging PDFs onto
   `PasswordProtect.cmd`** (or double-clicking it and dropping files in).

`-ClientSource` is optional if the client list already exists. Add
`-SkipClientPublish` to leave the client list alone.

## Mode B - Install (right-click menu, needs admin)

Best when you (or IT) can run an elevated PowerShell on each PC. Adds "Protect
with password" to the Explorer right-click menu for everyone on the machine.

1. Open an **Administrator** PowerShell in the tool folder and run the same
   command with `-Mode Install`:

   ```powershell
   .\setup.ps1 -Mode Install `
       -ClientListPath '\\server\shared\PDFProtect\clients.csv' `
       -EscrowDir      '\\server\data\PDFProtect-Escrow' `
       -ClientSource   '\\server\shared\Master\Clients.xlsx' `
       -PfxPath        'E:\curo-escrow.pfx'
   ```
2. When it prints `Setup complete`, right-click any PDF -> **Protect with
   password** (or **Protect and attach to new email**).

Install mode copies the tool to `C:\Program Files\CuroPDFProtect`, hardens the
`C:\ProgramData\CuroPDFProtect` folder (settings and the escrow certificate
become read-only for standard users), and registers the right-click menus.

To remove it: run `uninstall.ps1` as admin. The audit log is kept unless you
add `-PurgeAuditLog`.

---

## Key custody (read this)

Setup generates an escrow **key pair**:

- A **public certificate** (`escrow.cer`) is placed on each PC. It only
  *locks* passwords - it cannot recover them. It is safe to distribute.
- A **private key** (`.pfx`, protected by the password you chose) is written to
  the path you gave in `-PfxPath`. **This is the only thing that can recover a
  forgotten password.** Keep it OFFLINE - a USB stick in the office safe - and
  make a second copy stored off-site. If you lose it, no protected file can
  ever be recovered.

Store the `.pfx` password with the USB (they are useless apart, and both are
needed together for recovery).

---

## Verifying and troubleshooting

Setup runs a health check at the end. To re-run it any time, on the affected
PC:

```powershell
Import-Module .\src\Config.psm1
Test-CuroHealth
```

`Healthy = True` means good to go. Otherwise each issue names the component and
the next step. Common ones:

| Component          | Meaning / fix |
|--------------------|---------------|
| `settings.json`    | Setup was never run on this PC. Run `setup.ps1`. |
| `client list`      | The client-list path is unreachable. Check the share/synced folder; re-publish with `admin\Publish-Clients.ps1`. |
| `escrow certificate` | `escrow.cer` is missing. Re-run setup, or copy it from another PC's `%ProgramData%\CuroPDFProtect\`. |
| `escrow directory` | The escrow folder is unreachable. The tool refuses to protect without it (by design). Restore access. |
| `binary integrity` | A bundled program file is missing, modified, or unrecognised. Re-copy the tool folder from a trusted source. |
| `audit log`        | The audit folder isn't writable. Check permissions on `%ProgramData%\CuroPDFProtect\`. |

For a full support report to send on, run
`admin\Get-PDFProtectDiagnostics.ps1 -Copy` and paste the result.

If the right-click entry (Install mode) does nothing, or the launcher window
closes instantly, a diagnostic file is written to
`%LOCALAPPDATA%\CuroPDFProtect\error.log` - send that on.
