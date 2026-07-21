# Architecture

Final design. Reflects the decisions in `DECISIONS.md`.

## Component map

```
Explorer right-click on file.pdf
        │
        ▼
 HKLM\Software\Classes\*\shell\CuroProtectWithPassword\command
        │   "powershell.exe -NoProfile -ExecutionPolicy Bypass
        │    -File Protect-File.ps1 -Path %1"
        ▼
 src\Protect-File.ps1
        │
        ├─ Logging.psm1::Write-Heartbeat  (version, host, user)
        ├─ Config.psm1::Get-CuroConfig    (schema-version gated, fails closed)
        ├─ precheck: file exists, not locked, not already encrypted
        ├─ Find-Client.ps1::Get-ClientList
        │     ├─ tries \\server\shared\PDFProtect\clients.csv
        │     ├─ refreshes %ProgramData%\CuroPDFProtect\cache\clients.csv
        │     └─ falls back to cache if primary unreachable & cache < 48h
        │
        ├─ Prompt-Password.ps1 (WPF)
        │     ├─ type-ahead picker (Find-Client)  →  DOB as SecureString
        │     └─ manual PasswordBox + confirm + complexity check
        │
        ├─ Invoke-QPdf.ps1 (PDF only)
        │     ├─ long-path prefix on UNC / OneDrive paths
        │     ├─ writes to <out>.tmp, atomic rename on success
        │     └─ returns ErrorCode enum
        │
        ├─ Write-Escrow.ps1::Write-EscrowSidecar  (HARD FAIL if unreachable)
        │     └─ \\server\data\PDFProtect-Escrow\YYYY\MM\<sha>.escrow.json
        │
        ├─ Logging.psm1::Write-AuditEvent
        │     └─ %ProgramData%\CuroPDFProtect\audit.log  (JSONL)
        │
        ├─ Send-OutlookAttachment.ps1 (if requested)
        │     └─ 5s COM timeout → desktop-drop fallback
        │
        └─ Success toast + recipient hint boilerplate
```

## Directory layout

```
\Program Files\CuroPDFProtect\
├── VERSION
├── setup.ps1              (guided first-time setup; Install or Launcher mode)
├── src\
│   ├── Protect-File.ps1
│   ├── Protect-Folder.ps1
│   ├── Protect.psm1        (core protect-one-file chain)
│   ├── Prompt-Password.ps1
│   ├── Prompt-Drop.ps1     (drag-drop window for the standalone launcher)
│   ├── Show-CuroError.ps1  (loud-failure logging + notification helper)
│   ├── Find-Client.ps1
│   ├── Invoke-QPdf.ps1
│   ├── Write-Escrow.ps1
│   ├── Send-OutlookAttachment.ps1
│   ├── Config.psm1
│   └── Logging.psm1
├── admin\
│   ├── Publish-Clients.ps1
│   ├── Recover-File.ps1
│   ├── Rotate-EscrowKey.ps1
│   ├── Get-PDFProtectDiagnostics.ps1
│   └── Get-AuditSummary.ps1
├── bin\
│   ├── qpdf.exe           (SHA-256 pinned)
│   └── HASHES.txt
└── config\
    └── settings.default.json

\ProgramData\CuroPDFProtect\
├── settings.json          (from GPO-supplied path, or default)
├── escrow.cer             (RSA-4096 public key)
├── audit.log              (JSONL, 7-year retention)
└── cache\
    └── clients.csv        (local mirror, refreshed on each successful read)

\\server\shared\PDFProtect\
├── clients.csv            (weekly-published by Practice Admin)
└── settings.json          (optional central override)

\\server\data\PDFProtect-Escrow\
└── YYYY\MM\<sha>.escrow.json  (one per protected file)

\\server\deploy$\CuroPDFProtect\
├── VERSION
├── src\ admin\ bin\ config\    (identical layout to install dir)
├── escrow.cer
└── previous\                   (N-1 payload, for rollback)
```

## Configuration resolution

`src\Config.psm1` is the single config system. `Get-CuroConfigPath` resolves
which `settings.json` to load, in order:

1. `$env:CURO_SETTINGS_PATH` - explicit override (used by `setup.ps1` while it
   configures a machine, and by tests/CI).
2. `%ProgramData%\CuroPDFProtect\settings.json` - the machine-wide install.
3. `<tool root>\config\settings.json` - the no-admin **Launcher** deployment,
   written by `setup.ps1 -Mode Launcher`.

`config\settings.default.json` is a **template only** - it is never loaded
directly; its placeholder `\\server\...` paths pass syntax validation but fail
the health check, which is the point (a half-configured machine is caught).

`$env:CURO_SUPPRESS_UI=1` makes the error notifier log-only (no dialog) - used
by CI so a modal box can't hang a headless run.

## Password handling (critical path)

1. WPF `PasswordBox` or programmatically built `SecureString` from CSV DOB.
2. Never assigned to a managed `String`.
3. Marshalled to a BSTR only at the exact moment of child-process launch or
   escrow wrap; zeroed via `Marshal.ZeroFreeBSTR` immediately.
4. For `qpdf --encrypt`, the passwords are written to a short-lived `@argfile`
   (a temp file, locked to the current user, shredded and deleted immediately)
   and passed to qpdf as `@<path>`. They never appear on qpdf's command line
   (which is visible in Process Explorer/tasklist), and the argfile is written
   as BOM-less UTF-8 (a BOM makes qpdf misparse `--encrypt`). The flag form
   `--encrypt --user-password= --owner-password= --bits=256 --` is used.
5. Non-PDF 7z handling has been removed from v1 business mode.
6. Escrow wrap: UTF-8 bytes → `RSA-OAEP-SHA256` (via the CNG key) → base64 in
   the sidecar, recording `key_wrap_algorithm = rsa-oaep-sha256-cert`. If the
   escrow certificate exposes only a legacy CSP key, it falls back to
   OAEP-SHA1 (`rsa-oaep-sha1-cert`) rather than failing the protect; recovery
   reads the recorded algorithm, so both - and older schema-1 sidecars - stay
   recoverable. Plaintext bytes cleared with `Array.Clear` immediately after.
7. `SecureString` disposed in a `finally` block; `GC.Collect` called to
   encourage reclamation of any short-lived managed copies.

## Escrow sidecar schema

```json
{
  "schema_version": 2,
  "created_utc": "2026-04-14T10:22:03Z",
  "tool_version": "1.0.0",
  "host": "CURO-WS07",
  "user": "CURO\\alice",
  "source_filename": "SoA_Smith.pdf",
  "source_path": "C:\\Clients\\Smith-J\\SoA_Smith.pdf",
  "output_filename": "SoA_Smith_protected.pdf",
  "output_sha256": "abcd...64hex",
  "output_size_bytes": 184221,
  "cipher": "pdf-aes256",
  "key_wrap_algorithm": "rsa-oaep-sha256-cert",
  "public_key_fingerprint": "1234...40hex (cert thumbprint)",
  "pubkey_fingerprint_sha256": "1234...40hex",
  "wrapped_user_password_b64": "base64(RSA-OAEP(pubkey, utf8(user password)))",
  "wrapped_owner_password_b64": "base64(RSA-OAEP(pubkey, utf8(owner password)))",
  "client_file_ref": "C-00421",
  "password_source": "dob"
}
```

Legacy `schema_version: 1` sidecars used a single `wrapped_password_b64` and
SHA-1 OAEP; `admin\Recover-File.ps1` reads `key_wrap_algorithm` (defaulting to
SHA-1 when absent) so every generation stays recoverable.

One file per protected output. File name = `<output_sha256>.escrow.json`.
No concurrency problem across machines (each writes a unique filename).

## Audit log schema

JSONL, one event per line. Examples:

```json
{"ts":"2026-04-14T10:22:03Z","v":"1.0.0","host":"CURO-WS07","user":"CURO\\alice","op":"protect","event":"heartbeat","ps_edition":"Desktop","ps_version":"5.1.19041.4412"}
{"ts":"2026-04-14T10:22:04Z","v":"1.0.0","host":"CURO-WS07","user":"CURO\\alice","op":"protect","outcome":"ok","src_path":"C:\\Clients\\Smith-J\\SoA_Smith.pdf","dst_path":"C:\\Clients\\Smith-J\\SoA_Smith_protected.pdf","cipher":"pdf-aes256","bytes_in":182114,"bytes_out":184221,"duration_ms":412,"client_file_ref":"C-00421","password_source":"dob","deleted_original":false,"escrow_written":true,"escrow_fp":"1234...","output_sha256":"abcd..."}
{"ts":"2026-04-14T10:22:05Z","v":"1.0.0","host":"CURO-WS07","user":"CURO\\alice","op":"outlook_attach","outcome":"ok","outlook_mode":"New","error":null}
```

### error_code enum

The codes actually emitted by the core protect chain (`src\Protect.psm1`,
`src\Invoke-QPdf.ps1`), used for alerting and diagnostics:
- `OK`
- `INPUT_NOT_FOUND`
- `PDF_ONLY`
- `PRE_ENCRYPTED`
- `FILE_LOCKED`
- `QPDF_FAIL`
- `ESCROW_OFFLINE`

(An outcome of `cancel` is recorded when the user closes the picker.)

## Test matrix (Pester)

| # | Case | Expected |
|---|---|---|
| 1 | Normal PDF round-trip (protect → recover) | byte-equal to original |
| 2 | .docx input | refused as PDF_ONLY |
| 3 | Already-encrypted PDF | `PRE_ENCRYPTED`, no prompt shown |
| 4 | Locked PDF (open handle) | `FILE_LOCKED`, no partial output |
| 5 | Path > 260 chars | success via `\\?\` prefix |
| 6 | OneDrive-synced source | success |
| 7 | CSV stale 9 days | warn banner, still works |
| 8 | CSV stale 22 days | hard fail `CSV_OFFLINE` |
| 9 | Escrow share unreachable | `ESCROW_OFFLINE`, no output file |
| 10 | Apostrophe in client name | picker shows correctly |
| 11 | Two clients with same name | disambiguator by file_ref |
| 12 | Manual password < 10 chars | rejected |
| 13 | DOB with separators in CSV | normalised to 8 digits |
| 14 | qpdf binary hash mismatch | install.ps1 aborts |
| 15 | Pubkey rotated, old file recovery | succeeds with old private key |
| 16 | Two machines protecting same second | two sidecars, both succeed |

The table above is the design intent. The automated coverage that actually
runs lives in `tests\*.Tests.ps1` (Pester) plus the Windows CI workflow
(`.github/workflows/windows-ci.yml`), which on every push exercises: the real
qpdf encrypt/decrypt round-trip; the full protect chain (escrow + audit +
fail-closed-on-dead-escrow); guided `setup.ps1` end to end in both modes; the
escrow keygen -> wrap -> recover loop; audit-log concurrency; and binary-hash
tamper refusal. Run locally with `Invoke-Pester -Path .\tests`.

## Staged rollout

For a small practice, use the pilot plan in `docs\PILOT-CHECKLIST.md`
(set up -> prove recovery -> two pilot users -> whole team). The AD/GPO
"ring" model below is only worth the overhead at larger scale:
- `CuroPDFProtect-Ring0`: 3 machines, 1 week soak.
- `CuroPDFProtect-Ring1`: ~5 machines, 1 week soak.
- `CuroPDFProtect-Ring2`: remainder of the practice.

## Failure-mode summary

| Failure | Behaviour | Recovery |
|---------|-----------|----------|
| Config missing/invalid | Refuse to run, message box (or `%LOCALAPPDATA%\CuroPDFProtect\error.log` from a hidden shim) | Run `setup.ps1` |
| CSV share unreachable, cache < 48h | Use cache, warn banner | Resolve network |
| CSV share unreachable, cache > 48h | Prompt still opens; picker empty; manual path available | Resolve network; next read refreshes cache |
| PDF already encrypted | Refuse, suggest removing existing protection | Open in Acrobat and save without security first |
| File locked | Refuse, ask user to close in Acrobat | Close file, retry |
| Escrow share unreachable | Refuse-closed; protected file NOT produced | Resolve network, retry |
| qpdf exit code ≠ 0 | Refuse; delete temp output; log `QPDF_FAIL` | Contact IT with diagnostics |
| Outlook COM timeout | Desktop-drop fallback; protect succeeds regardless | User attaches manually |

## Non-goals for v1

- Watched drop folder / bulk scheduled automation (flagged by EDR as
  ransomware-like; revisit in v1.x after EDR whitelist matures).
- Certificate-based document encryption (S/MIME / MS Purview).
- Password strength enforcement beyond the manual policy (DOB path is
  intentionally exempt).
- Cross-platform support (Windows-only).
