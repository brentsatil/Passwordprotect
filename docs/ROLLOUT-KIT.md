# Rollout kit - copy-and-paste artefacts

Everything here is meant to be used verbatim. `docs\PILOT-CHECKLIST.md` is the
*sequence* (day 0, week 1, week 2); this is the *content* for each step.

Chosen storage layout for this deployment:

| What | Where | Why |
|---|---|---|
| Escrow (recovery records) | UNC share on the file server | A write either succeeds or fails immediately. The tool refuses to protect a file it cannot escrow, and that guarantee is only real if the write is real. |
| Client list (`clients.csv`) | OneDrive / SharePoint synced folder | The practice admin republishes it weekly from the master spreadsheet; a synced folder is the convenient place for that. |
| Escrow private key (`.pfx`) | USB in the safe, second copy off-site | Never on a PC, never on the share. |

> **Why escrow is deliberately NOT in OneDrive.** A synced folder reports a write
> as successful the moment it lands on the local disk. If that PC dies before the
> file syncs, the protected document exists and its recovery record does not -
> which is precisely the situation the fail-closed design exists to prevent. On a
> UNC share the write is confirmed by the server or it fails and the tool refuses.

---

## 1. Admin command sheet

### 1a. Set these once per console session

Paste this block first; every command below uses it, so the paths cannot drift
between commands.

```powershell
# ---- EDIT THESE FOUR LINES -------------------------------------------------
$Server    = 'CURO-FS01'                                   # your file server / NAS name
$OneDrive  = "$env:USERPROFILE\OneDrive - Curo Financial Services"
$UsbPfx    = 'E:\curo-escrow.pfx'                          # the recovery USB drive letter
$Operators = @('CURO\brent', 'CURO\ian')                   # who may READ escrow records
# ---------------------------------------------------------------------------

$EscrowDir = "\\$Server\Data\PDFProtect-Escrow"
$ClientCsv = "$OneDrive\PDFProtect\clients.csv"
$MasterXls = "$OneDrive\Master\Clients.xlsx"

# Sanity-check before going further - all three must print True/exist.
Test-Path "\\$Server\Data"          # the escrow parent must already exist
Test-Path (Split-Path $ClientCsv)   # the OneDrive PDFProtect folder
Test-Path $MasterXls                # the master client spreadsheet
```

### 1b. Record the exe hash you are publishing

The `PasswordProtect-portable-exe` artifact contains the exe **and** a
`PasswordProtect.exe.sha256` file with that build's hash, so it travels with the
download - no need to trust a hash typed into a document. Confirm the copy you
put on the share matches:

```powershell
Get-FileHash '\\CURO-FS01\Apps\PasswordProtect\PasswordProtect.exe' -Algorithm SHA256
Get-Content  '\\CURO-FS01\Apps\PasswordProtect\PasswordProtect.exe.sha256'
```

Keep both files together on the share. The hash also appears in the
`windows-ci` log under *"PasswordProtect.exe (the file you hand to staff)"*.

### 1c. Lock down the escrow share (once, before anyone protects anything)

Staff need to *write* recovery records without being able to *read* each other's.

```powershell
.\admin\Set-EscrowShareAcl.ps1 -EscrowDir $EscrowDir -RecoveryOperator $Operators
```

### 1d. Your PC - this is what creates the escrow key

Run this **once**, on your machine, before anybody else is set up.

```powershell
.\setup.ps1 -Mode Launcher `
    -ClientListPath $ClientCsv `
    -EscrowDir      $EscrowDir `
    -ClientSource   $MasterXls `
    -PfxPath        $UsbPfx
```

It prompts you to choose a password for the `.pfx`. Write it down and keep it
**with the USB** - they are useless apart and both are needed to recover.

Expect to see, near the end:

```
[OK]   Generated a new escrow key pair and published the certificate
[OK]   Published <n> clients
[OK]   Health check: Healthy
Setup complete
```

### 1e. Prove recovery works, before any real client file exists

Non-negotiable. If this does not work, nothing else matters.

```powershell
# Protect a throwaway PDF first (drag any test PDF onto PasswordProtect.exe),
# then recover its password:
.\admin\Recover-File.ps1 -PrivateKeyPath $UsbPfx -SourceName 'test.pdf'
```

The recovered password lands on your clipboard and must equal that client's DOB.

### 1f. Every other PC - it must ADOPT the key, never create one

Same command, **minus `-PfxPath`**:

```powershell
.\setup.ps1 -Mode Launcher `
    -ClientListPath $ClientCsv `
    -EscrowDir      $EscrowDir `
    -SkipClientPublish
```

You are looking for this line:

```
[OK]   Adopted the existing deployment escrow certificate (fingerprint <...>)
```

**If it says "Generated" instead, stop.** That PC would encrypt client files
your recovery USB cannot open, and nothing would reveal it until a client asked
for their password back. Check the PC can reach `$EscrowDir` and re-run.

Confirm any time, on any PC:

```powershell
Import-Module .\src\Config.psm1
(Test-CuroHealth).Issues        # must NOT list "escrow key"
```

### 1g. Optional - main-menu right-click on Windows 11

```powershell
# Needs an elevated PowerShell once per PC with the default self-signed cert.
.\shellext\Install-ShellExt.ps1 -PackageDir 'C:\Program Files\CuroPDFProtect\shellext'
```

Without this the verb still works, but sits under *Show more options*. See
`docs\ADMIN-SETUP.md`.

### 1h. Rare: re-key a protected PDF you no longer have the original of

```powershell
# Prompts for the CURRENT password; new password = that client's DOB.
.\admin\Set-PdfPassword.ps1 -Path '<the protected pdf>' -ClientRef 'C-00101'
```

Only when the unprotected original is gone. If you still have it, correct the
client list and protect it again instead - simpler, and it leaves no stale copy.
The client's existing copy keeps opening with the OLD password.

### 1i. The ongoing rhythm

```powershell
# Weekly - refresh the client list from the master spreadsheet
.\admin\Publish-Clients.ps1 -Source $MasterXls

# Weekly - read the audit summary (look for any 'fail' outcome)
.\admin\Get-AuditSummary.ps1 -Days 7

# Monthly - collect each PC's audit log into the archive (7-year retention)
.\admin\Export-AuditArchive.ps1 -ArchiveRoot "\\$Server\Data\PDFProtect-AuditArchive"

# Yearly - rotate the escrow key (keep every retired USB forever)
.\admin\Rotate-EscrowKey.ps1
```

---

## 2. Email to staff

Send this once each teammate's PC has been set up and you have run the
acceptance pass. Attach or paste `docs\CHEATSHEET.md`.

> **Subject:** New way to password-protect client PDFs - please use this from now on
>
> Hi all,
>
> From today, please use **Curo PDF Protector** whenever you send a client a PDF
> that contains their personal or financial information. It replaces doing it by
> hand in Acrobat, and it means we can always recover a password if a client
> loses theirs.
>
> **Where it is:** `\\CURO-FS01\Apps\PasswordProtect\PasswordProtect.exe`
> *(make a shortcut to it on your desktop - don't copy the file itself, so you
> always get the current version)*
>
> **How to use it - three steps:**
>
> 1. Select the PDF or PDFs and drag them onto the shortcut.
> 2. A window lists your files. Most will already show the right client, matched
>    from the file name. If a row says **Needs client**, click it and type a few
>    letters of the client's surname, then pick them from the list.
> 3. Click **Protect all**. You get a new `..._protected.pdf` next to each
>    original. The originals are untouched.
>
> **The password is the client's date of birth**, eight digits, day-month-year,
> no spaces or slashes. 3 December 1970 is `03121970`.
>
> **Please tell the client the password by phone or SMS - never in the same email
> as the file.** Wording that works: *"The password is your date of birth, eight
> digits, day then month then year. So 3 December 1970 would be 03121970."*
>
> **Two things to expect the first time:**
>
> - Windows may show a blue *"Windows protected your PC"* screen. That is Windows
>   not recognising an in-house tool, not a virus warning. Click **More info**,
>   then **Run anyway**. Tell me if you see it and I will clear it centrally.
> - It can pause a few seconds per file while it works. That is normal.
>
> **If a client says the password doesn't work**, check their date of birth in
> our client list matches what they've told you - and if you're still stuck, come
> to me. I can recover the exact password for any file the tool has produced.
>
> The one-page guide is attached - worth keeping by your desk for the first week.
> Any questions, or anything that looks wrong, tell me rather than working around
> it.
>
> Thanks,
> Brent

---

## 3. What to say if someone asks "is this secure?"

Short answers that are true:

- The PDFs use **AES-256** encryption, the same standard Acrobat uses. A
  protected file cannot be opened without the password.
- **Every** password is recorded, encrypted, to a recovery store that only the
  named recovery operators can read. Nobody at Curo can see a password by
  looking at the store; it takes the offline key from the safe.
- Every protect is **logged** (who, when, which file, which client reference) and
  those logs are retained for seven years.
- The tool **refuses to protect a file** if it cannot write the recovery record
  first. There is deliberately no way to end up with a protected file nobody can
  recover.
- Using the client's date of birth as the password is a **usability decision, not
  a security maximum** - it is guessable by anyone who knows the client. It is
  appropriate for "stop the wrong person casually opening this in transit", not
  for defending against a determined attacker who has the file. This is recorded
  as an open decision in `docs\DECISIONS.md` #23 and should carry a director's
  sign-off before wide use.
