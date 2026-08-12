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

## Mode 0 - Portable exe (easiest to hand out)

Best when you just want to give someone a file. `PasswordProtect.exe` is one
self-contained ~7.6 MB file containing this entire tool. There is no folder to keep
together and no console window - and it runs the *same* scripts, so escrow, the
audit log and the PDF-only rule all still apply.

Get it by either:

- downloading the `PasswordProtect-portable-exe` artifact from the latest
  `windows-ci` run on `main` (uploaded on every push to `main`, and on manual
  runs), or
- building it: `dotnet publish launcher\CuroPdfProtect.Launcher -c Release -o publish`

### Getting it to the team safely

- **Put it on a share that staff can read and only IT can write.** The exe is the
  one binary here with no hash pinning protecting it - everything inside `bin\`
  is SHA-256 verified, but the exe that carries them is not. Anyone who can write
  to that share effectively owns every PC that runs it. `Users: Read & Execute`,
  write restricted to you.
- **Record its hash** when you publish it, so you can confirm what staff are
  running: `Get-FileHash .\PasswordProtect.exe -Algorithm SHA256`. Compare with
  `PasswordProtect.exe --version`, which prints the payload id.
- **Do not email it.** A `.exe` attachment is stripped by essentially every mail
  filter and by M365 Safe Attachments.
- **Expect a Mark-of-the-Web prompt** if it arrives via a browser download (the
  CI artifact is a downloaded zip - the highest-risk route) or from a share in an
  untrusted zone. The user sees a full-screen blue **"Windows protected your PC"**
  whose only visible button is *Don't run*; they must click **More info -> Run
  anyway**. Staff reasonably read this as "IT says this is malware". Clear it once
  centrally instead:

  ```powershell
  Unblock-File .\PasswordProtect.exe      # or: right-click -> Properties -> Unblock
  ```

  Adding the share to **Local intranet / Trusted sites** stops the mark being
  applied in the first place. Windows 11 (June 2024+) applies MotW to files from
  untrusted networks, so a share reached by FQDN or IP often counts as Internet.
- **Check Smart App Control** on one machine before you roll out (Windows
  Security -> App & browser control). On a clean-installed Windows 11 it blocks
  unsigned executables regardless of MotW, and `Unblock-File` will not help. If
  it is on, you need a signing certificate - see `docs\DECISIONS.md` #14.

Then, once per machine:

1. Copy `PasswordProtect.exe` anywhere (a shared drive is fine).
2. Run `PasswordProtect.exe --setup` and answer the prompts. It asks for the escrow
   `.pfx` password rather than taking it as an argument, deliberately - a password on
   a command line is visible in the process list.
3. Day to day, staff **drag PDFs onto the exe** or double-click it for the drop window.

Useful verbs:

| Command | What it does |
|---|---|
| `PasswordProtect.exe --setup` | first-time setup on this machine |
| `PasswordProtect.exe --diagnose` | reports *why* scripts may be blocked here (see below) |
| `PasswordProtect.exe --verify` | re-extracts and hash-checks the embedded tool |
| `PasswordProtect.exe --version` | payload id and cache folder |

**If staff see a red "running scripts is disabled on this system", the exe cannot fix
it.** The tool already passes `-ExecutionPolicy Bypass`; if scripts are still blocked
then Group Policy, AppLocker or WDAC is responsible and *overrides* that flag. Run
`--diagnose` and send the output to IT: the fix is an allowlist, or Authenticode-signing
the scripts (see the code-signing note in `docs\DECISIONS.md` #14).

The exe supplements the two modes below - it does not replace them. Use Mode B if you
want the Explorer right-click menu.

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

### Optional - Windows 11 main-menu right-click (`shellext\`)

On Windows 11 the Install-mode verbs live under **Show more options** - that is
how Windows 11 treats every registry-based verb, not a fault. If you want
**Protect with password** in the MAIN right-click menu, install the modern
context-menu package as well:

1. Get the package: download the `CuroPDFProtect-shellext` artifact from the
   latest `windows-ci` run on `main`, or build it on a PC with VS Build Tools +
   the Windows SDK: `shellext\Build-ShellExt.ps1 -LauncherExe <path-to-exe>`.
2. Put the folder somewhere **permanent** (e.g.
   `C:\Program Files\CuroPDFProtect\shellext`) - the install refuses temp
   locations because Windows records the folder as the package's home.
3. Run `shellext\Install-ShellExt.ps1 -PackageDir <that folder>`. With the
   default self-signed certificate this needs an **elevated** PowerShell once
   per PC (it trusts the certificate into the machine's Trusted People store);
   with a CA-issued certificate no elevation is needed. Explorer restarts.

Notes:

- Windows 11 (build 22000+) only; the script refuses Windows 10, where the
  normal menu already shows registry verbs.
- The entry is **PDF-only** and greys out if the selection contains anything
  else. It launches the same `PasswordProtect.exe` - same escrow, same audit.
- The legacy entries (if Install mode is present) remain under *Show more
  options*; both run the identical tool. `shellext\Uninstall-ShellExt.ps1`
  removes this one, `uninstall.ps1` removes those.
- A sparse package **cannot install unsigned** - that is a Windows rule. The
  self-signed route works for an internal fleet; a signing service (e.g. Azure
  Artifact Signing, ~USD10/month) removes the per-PC trust step. See
  `docs\DECISIONS.md` #14.

---

## Key custody (read this)

### One key for the whole team - generated once, never per PC

This is the single most important thing to get right.

- **The first PC you set up generates the escrow key pair** and publishes the
  public certificate to `<your escrow folder>\_deployment\escrow.cer`.
- **Every other PC adopts that certificate automatically.** Run the same setup
  command on them but leave `-PfxPath` and `-PfxPassword` off. You will see
  `[OK] Adopted the existing deployment escrow certificate (...)`.
- **Do not generate a key on each machine.** A PC wrapping under its own key
  produces files your recovery `.pfx` **cannot open**, and nothing reveals it
  until a client asks for a password back. Setup now refuses to mint a second
  key when a deployment key exists, and the health check reports an
  `escrow key` problem if a mismatch ever appears.
- **Rotation is also once.** `admin\Rotate-EscrowKey.ps1` publishes the new
  certificate to the same shared location so every PC picks it up. Keep every
  retired `.pfx` forever - files protected under an old key can only be
  recovered with that old key.

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
