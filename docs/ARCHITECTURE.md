# Architecture (proposed)

Subject to the decisions in `DECISIONS.md`. This is the design I'd implement
under the recommended defaults (escrow **on**, per-user passwords, delete
original opt-in, MSI + `install.ps1`, automation = right-click + folder batch
only for v1).

## Component map

```
Explorer right-click
        │
        ▼
 HKCU\Software\Classes\*\shell\ProtectWithPassword\command
        │   "powershell.exe -NoProfile -File Protect-File.ps1 -Path %1"
        ▼
 Protect-File.ps1   ◄──── Config.psm1 (policy, paths, escrow pubkey)
        │
        ├── detects file type
        ├── shows WPF prompt (Prompt-Password.ps1)
        │       └── SecureString, complexity check, "delete original" toggle
        │
        ├── PDF  → qpdf.exe --encrypt <user> <owner> 256 -- in.pdf out.pdf
        └── else → 7z.exe a -t7z -mhe=on -mx=5 -p<pw> out.7z in.*
                  (password piped via stdin, never on argv)
        │
        ▼
 Audit log: %ProgramData%\PasswordProtect\audit.log   (append-only, ACL'd)
```

## Directory layout

```
/
├── README.md
├── install.ps1                  # registers context menu, verifies deps
├── uninstall.ps1
├── src/
│   ├── Protect-File.ps1         # entry point invoked by Explorer
│   ├── Protect-Folder.ps1       # batch mode
│   ├── Prompt-Password.ps1      # WPF dialog, returns SecureString
│   ├── Invoke-QPdf.ps1          # wrapper, stdin-based
│   ├── Invoke-SevenZip.ps1      # wrapper, stdin-based
│   ├── Write-AuditLog.ps1
│   └── Config.psm1              # load %ProgramData%\PasswordProtect\config.json
├── config/
│   └── config.default.json      # shipped defaults; admin-editable at install
├── tools/                       # bundled dependencies (verified at install)
│   ├── qpdf/qpdf.exe
│   └── 7zip/7z.exe
├── installer/
│   └── PasswordProtect.wxs      # WiX source for the MSI
├── tests/
│   ├── Protect-File.Tests.ps1   # Pester tests
│   └── fixtures/                # sample PDF + docx + jpg
└── docs/
    ├── RISK.md
    ├── DECISIONS.md
    └── ARCHITECTURE.md          # this file
```

## Password handling (critical path)

1. User right-clicks → `Protect-File.ps1 -Path <file>`.
2. Script calls `Prompt-Password.ps1` which shows a WPF dialog with a
   `PasswordBox` (SecureString only — the plaintext never enters .NET
   managed string space).
3. Complexity check runs on the SecureString via a constant-time
   length/class check that does not materialise the password as a
   `String`.
4. The SecureString is marshalled to an unmanaged BSTR, written to the
   child process's stdin, and the BSTR is zeroed immediately
   (`Marshal.ZeroFreeBSTR`).
5. `qpdf` / `7z` receive the password via stdin only. `%CommandLine%`
   in Process Explorer shows no secret.
6. On process exit, the SecureString is disposed.

No plaintext password is ever:
- assigned to a `String` variable,
- passed on the command line,
- written to any log,
- persisted between invocations.

## Escrow (if decision 1 = yes)

- On install, `install.ps1` generates a 4096-bit RSA keypair. The public
  key is written to `%ProgramData%\PasswordProtect\escrow.pub`. The
  private key is written once to a path the admin specifies
  (USB / HSM / sealed envelope) and then deleted from disk.
- When protecting a file, the script generates a random 32-byte file-key
  `K`, encrypts the file with `K`, and writes
  `RSA-OAEP(escrow.pub, K)` as a sidecar file `filename.7z.escrow` (or
  embedded in PDF metadata for PDFs).
- `Recover-File.ps1` (admin-only) takes the sidecar and the private key
  and emits `K`, which is then used to decrypt the file.
- The user-typed password is mixed in via PBKDF2 so a compromised escrow
  key alone does NOT unlock files without also compromising the user
  password — escrow is recovery, not a backdoor-by-default. (Document
  this trade-off clearly.)

## Audit log

Append-only JSON lines at `%ProgramData%\PasswordProtect\audit.log`.
ACL: SYSTEM + BUILTIN\Administrators full, Users append-only.

```json
{"ts":"2026-04-14T10:22:03Z","user":"DOMAIN\\alice","op":"protect",
 "src":"C:\\Quotes\\Q-2026-041.pdf","dst":"C:\\Quotes\\Q-2026-041.pdf",
 "cipher":"pdf-aes256","deleted_original":false,"outcome":"ok"}
```

Shipped with a daily rotation via Scheduled Task (keep 90 days by default).

## Testing

- Pester tests cover: argument parsing, file-type detection, qpdf
  wrapper, 7z wrapper, complexity validation, audit log formatting.
- End-to-end smoke test: protect a PDF, decrypt it with a fresh `qpdf`
  call, check byte-equal round-trip.
- CI not set up in v1 (this is a PowerShell-on-Windows tool; a GitHub
  Actions Windows runner is v2).

## Rollout plan

1. Pilot: 3 users, 2 weeks. Daily check-in on tickets and audit log.
2. Department rollout: add one department, 2 weeks soak.
3. Business-wide rollout behind MDM.
4. EDR vendor notified before step 1 with the signed binary hash.
