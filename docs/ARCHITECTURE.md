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
        ├─ Invoke-QPdf.ps1 (PDF)   OR   Invoke-SevenZip.ps1 (other)
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
├── src\
│   ├── Protect-File.ps1
│   ├── Protect-Folder.ps1
│   ├── Prompt-Password.ps1
│   ├── Find-Client.ps1
│   ├── Invoke-QPdf.ps1
│   ├── Invoke-SevenZip.ps1
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
│   ├── 7z.exe             (SHA-256 pinned)
│   └── HASHES.txt
└── config\
    └── settings.default.json

\ProgramData\CuroPDFProtect\
├── settings.json          (from GPO-supplied path, or default)
├── escrow.pub             (RSA-4096 public key)
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
├── escrow.pub
└── previous\                   (N-1 payload, for rollback)
```

## Password handling (critical path)

1. WPF `PasswordBox` or programmatically built `SecureString` from CSV DOB.
2. Never assigned to a managed `String`.
3. Marshalled to a BSTR only at the exact moment of child-process launch or
   escrow wrap; zeroed via `Marshal.ZeroFreeBSTR` immediately.
4. For `qpdf --encrypt`, passed as argv (qpdf's only supported channel).
   The process lives for well under a second; argv is only visible to
   processes running as the same user; `%CommandLine%` is never logged.
5. For `7z`, same — passed as `-p<pw>` argv, never logged.
6. Escrow wrap: UTF-8 bytes → `RSA-OAEP-SHA256` → base64 in the sidecar.
   Plaintext bytes cleared with `Array.Clear` immediately after wrap.
7. `SecureString` disposed in a `finally` block; `GC.Collect` called to
   encourage reclamation of any short-lived managed copies.

## Escrow sidecar schema

```json
{
  "schema_version": 1,
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
  "pubkey_fingerprint_sha256": "1234...64hex",
  "wrapped_password_b64": "base64(RSA-OAEP-SHA256(pubkey, utf8(password)))",
  "client_file_ref": "C-00421",
  "password_source": "dob"
}
```

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

Finite, documented. Used for alerting and diagnostics:
- `INPUT_NOT_FOUND`
- `PRE_ENCRYPTED`
- `FILE_LOCKED`
- `CSV_OFFLINE`
- `ESCROW_OFFLINE`
- `QPDF_FAIL`
- `SEVENZIP_FAIL`
- `POLICY_REJECT`
- `USER_CANCEL`

## Test matrix (Pester)

| # | Case | Expected |
|---|---|---|
| 1 | Normal PDF round-trip (protect → recover) | byte-equal to original |
| 2 | .docx → 7z round-trip | byte-equal |
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

Run: `Invoke-Pester -Path .\tests` on the pilot machine weekly.

## Staged rollout

Three AD security groups filter the GPO:
- `CuroPDFProtect-Ring0`: Brent + paraplanner + one adviser (3 machines).
- `CuroPDFProtect-Ring1`: 5 advisers.
- `CuroPDFProtect-Ring2`: remainder of the practice.

Each ring soaks for 1 week. Daily check-in during Ring0 soak; day-end
review during Ring1.

## Failure-mode summary

| Failure | Behaviour | Recovery |
|---------|-----------|----------|
| Config missing/invalid | Refuse to run, message box | Re-run `install.ps1` |
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
