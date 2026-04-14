# Password Protect

A Windows right-click "Protect with password" tool for a small business. Lets
staff add password protection to PDFs and other files from Explorer, with an
automation path (batch-protect folders, watched drop folders) and
centrally-managed policy.

> **Status:** design phase. Implementation is blocked on the decisions listed
> in [`docs/DECISIONS.md`](docs/DECISIONS.md). Do not deploy anything from this
> repo yet.

## What it will do

- Right-click a file in Explorer → **Protect with password**.
- Right-click a folder → **Protect all files in folder**.
- PDFs get real PDF AES-256 encryption (via `qpdf`).
- Other files are placed in an AES-256 encrypted `.7z` archive (via `7-Zip`).
- A WPF password prompt uses `SecureString` — the password is never written to
  a command line, a log file, or PowerShell history.
- Optional watched drop folder that auto-protects files on arrival
  (scoped to an allowlist, run as a Scheduled Task).
- Append-only audit log in `%ProgramData%\PasswordProtect\audit.log`.

## What it will deliberately NOT do

- Invent its own crypto. It shells out to `qpdf` and `7z`, which are the
  standard tools for these jobs.
- Use legacy ZipCrypto (broken) or 40-bit / RC4 PDF encryption (broken).
- Store or log plaintext passwords anywhere, ever.
- Offer "password recovery" unless key escrow is explicitly enabled at
  install time (see [`docs/RISK.md`](docs/RISK.md) item 1).

## Why not just use Microsoft Purview / AIP / BitLocker?

For **regulated data** (PHI, PCI, legal, HR) you probably should — see
[`docs/RISK.md`](docs/RISK.md) item 10. This tool is aimed at the everyday
"email a quote to a client with a password" use case, not compliance
workloads.

## Documents in this repo

- [`docs/RISK.md`](docs/RISK.md) — risk register. Read this first.
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — decisions needed from the
  business owner before implementation starts.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — proposed technical design.

## Deployment target

- Windows 10 / 11, PowerShell 5.1+ (ships with Windows).
- Deployed per-machine via MSI + Intune / GPO, or per-user via `install.ps1`.
- Dependencies: `qpdf` (Apache-2.0), `7-Zip` (LGPL) — both redistributable.
