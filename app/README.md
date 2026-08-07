# PasswordProtect — native .NET 8 app

> ## Status: EXPLORATORY — not the supported tool, and not safe for client files
>
> **The supported product for Curo is the PowerShell tool in the repo root** (see the
> root `README.md`, `docs/ADMIN-SETUP.md`, `docs/PILOT-CHECKLIST.md`). This app is an
> earlier, parallel prototype that predates the PDF-only rework and the rollout
> hardening. It was merged to `main` to preserve the work, **not** to ship it.
>
> It does **not** implement the guarantees the firm's process depends on:
>
> | Guarantee (root tool) | This app |
> |---|---|
> | Fail-closed RSA escrow — no protected file without a recovery record | **None.** No sidecar is ever written. |
> | 7-year JSONL audit log (Corps Act s.988A / ASIC RG 104) | **None.** No event is ever logged. |
> | PDF-only in v1 business mode | Also encrypts Office documents. |
> | Client list / DOB passwords from `clients.csv` | Not read; passwords are typed free-form. |
> | Passwords kept off child-process command lines | Passed as process arguments. |
>
> **Consequence:** if someone protects a client file with this app and forgets the
> password, `admin\Recover-File.ps1` **cannot recover it** — there is no escrow record —
> and no audit entry exists to show the operation happened. With *Overwrite in place*
> ticked, the plaintext original is replaced, so the data is permanently gone.
>
> Do not use it on real client documents. Whether this app is fixed, scoped to
> non-client use, or removed is an open decision — see entry 25 in `docs/DECISIONS.md`.

A self-contained Windows desktop app that bulk password-protects and re-keys
documents, with a GUI, smart naming, and password editing. It shares the repo's
bundled `qpdf.exe` but is otherwise independent of the root tool.

## What it does

- **Bulk protect** many mixed files at once: drag-drop or *Add Files*, type one
  password, click **Apply**. Per-file status, runs in parallel, one bad file
  never stops the rest.
- **Per-type encryption (your choice):**
  - PDF → native AES-256 via qpdf.
  - Word/Excel/PowerPoint → **native ECMA-376 agile encryption**, or `.7z`.
    Implemented from scratch in `OfficeCrypto` per MS-OFFCRYPTO (AES-256-CBC +
    SHA-512 + HMAC via `System.Security.Cryptography`, CFB container via OpenMcdf) —
    NPOI's agile write path is broken on .NET, so it is not used.

    **Caveats on this hand-rolled implementation — read before relying on it:**
    - The tests prove **self-consistency only**: they encrypt and decrypt with this
      same code over a synthetic zip (`OfficeCryptoTests.MakeFakeOoxmlPackage`). There
      is no known-answer vector, no fixture produced by Microsoft Office, and no
      cross-check against an independent implementation. A symmetric mistake would
      still pass. **Confirm a file opens in real Microsoft Office** before trusting it.
    - `Encrypt` writes the MS-OFFCRYPTO `dataIntegrity` HMAC, but `TryDecrypt` never
      verifies it, so decryption is **unauthenticated** — a tampered or corrupted file
      decrypts without error (AES-CBC with `PaddingMode.None` raises nothing). This
      matters most on *Change*/*Remove password*, which can therefore emit a silently
      corrupted document as a successful result.
    - The container omits the `\x06DataSpaces` storage that the spec describes. This
      is a conformance gap rather than a known breakage, which is exactly why the
      manual Office check above is not optional.
  - Anything else → AES-256 `.7z` — **currently non-functional.** `7z.exe` was removed
    from the repo's `bin\` when the business flow went PDF-only, and the app embeds
    that folder as its payload, so no 7-Zip binary is shipped. These jobs fail per
    file with "The system cannot find the file specified". The 7z tests self-skip.
- **Smart naming:** an editable template with tokens — `{OriginalName}`, `{Ext}`,
  `{Date}`, `{DDMMYYYY}`, `{YYYYMMDD}`, `{Seq}`, plus `{DetectedName}` /
  `{DetectedDate}` pulled (best-effort) from inside the document. **Preview**
  shows the planned output name before you apply. Names are sanitized and
  collision-safe.
- **Overwrite or new file:** by default a new protected file is created next to
  the original; tick *Overwrite in place* to replace the original (confirmed).
- **Password editing:** the *Action* selector switches between **Protect**,
  **Change password**, and **Remove password** — bulk re-keying / rotation across
  many already-protected files (you supply the current password).
- **Right-click integration:** *Protect with password* in Explorer's context menu
  for `.pdf/.docx/.xlsx/.pptx`, registered per-user (no admin).

## Run it

It is a single portable `.exe` — copy it to a shared drive and run it. No install,
no .NET runtime needed (self-contained). On first run it extracts the bundled
binaries to a per-user cache (`%LOCALAPPDATA%\PasswordProtect\bin`), re-hashing each
one against the embedded `HASHES.txt` on every start.

Two gaps in that provisioning worth knowing: the cache lives in a user-writable
directory, and `GetSevenZipPathAsync` returns a `7z.exe` path from it **without any
existence or hash check** — so dropping an arbitrary `7z.exe` there would re-enable the
archive path with an unpinned binary. Only files listed in the embedded `HASHES.txt`
are ever extracted or verified.

Right-click menu (per-user, no admin):

```
PasswordProtect.exe --register-context-menu
PasswordProtect.exe --unregister-context-menu
```

## Build & publish

```powershell
# Build + run the headless test suite (Core is WPF-free)
dotnet test app/PasswordProtect.Tests/PasswordProtect.Tests.csproj -c Release

# Produce the portable single-file, self-contained exe
dotnet publish app/PasswordProtect.App/PasswordProtect.App.csproj `
  -c Release -r win-x64 --self-contained `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:EnableCompressionInSingleFile=true -o publish
```

CI (`.github/workflows/app-ci.yml`, windows-latest) runs the tests, compiles the WPF
app, and verifies the portable exe publishes on every push. Note what the suite does
**not** cover: the 7z round-trips self-skip (no `7z.exe` in `bin\`), the Office tests
are self-consistency only (see the caveats above), and nothing asserts Microsoft Office
compatibility. Dependencies are restored unlocked and NuGet audit warnings do not fail
the build — `OpenMcdf 2.3.1` currently carries two advisories
(GHSA-5qwm-7pvp-w988, GHSA-jxpf-xq2m-q525; an infinite-loop DoS on malformed compound
files, reachable from the *Change*/*Remove password* path and first fixed in the 3.x
API, which is a port rather than a version bump).

## Code signing (recommended reading)

The exe works unsigned, but Windows SmartScreen / antivirus trust *signed*
publishers. For this portable, shared-drive deployment:

1. **Ask IT whether the business already owns a code-signing certificate.** Most
   established firms do. If so, sign during publish (zero warnings):
   ```powershell
   dotnet publish ... -p:SignCertThumbprint=<thumbprint-in-cert-store>
   # or
   dotnet publish ... -p:SignCertPfx=cert.pfx -p:SignCertPassword=***
   ```
   The signing step (`PasswordProtect.Build/Sign.targets`) is a no-op when no
   cert is supplied, so unsigned builds keep working.
2. **No certificate?** Running from a *trusted internal share* can avoid the
   Mark-of-the-Web prompt, but this depends on the share's security zone and is
   no longer a safe assumption: Windows 11 (June 2024 and later) applies MotW to
   files from untrusted networks, and the 24H2 security baseline ships the
   "Do not apply the Mark of the Web tag to files copied from insecure sources"
   policy **Disabled**. A share reached by FQDN or IP commonly lands in the
   Internet zone. Add it to Local intranet / Trusted sites, or have users run
   `Unblock-File`. Note this only removes the *zone* mark — it does nothing about
   an unsigned publisher.
3. **Buying one is worth it, but not for the reason people expect.**
   - **EV certificates have not bypassed SmartScreen since 2024.** Microsoft:
     *"EV certificates no longer bypass SmartScreen... Paying a premium for EV
     solely to avoid SmartScreen warnings is no longer justified."* The claim
     that EV grants instant reputation used to be true and is now wrong.
   - Signing of any kind does **not** clear the warning immediately: reputation
     accrues per file hash and *"can take several weeks and hundreds of clean
     installs from a wide audience"* — a volume a small practice will never hit.
   - What signing actually buys: a **named publisher** instead of "Unknown
     publisher", the ability to allowlist by publisher rather than by a hash
     that changes every build, and eligibility under Smart App Control. Sign
     every release — unsigned files cannot inherit reputation from the cert.
   - Cheapest practical route: **Azure Artifact Signing (~$10/month)**, no
     hardware token, works from CI.
4. **Check Smart App Control** (Windows Security -> App & browser control). On a
   clean-installed Windows 11 it blocks unsigned executables *regardless* of
   MotW, and once turned off it cannot be re-enabled without reinstalling
   Windows — so behaviour differs between a factory-fresh laptop and an
   in-place upgrade. Takes a minute to check and decides whether an unsigned
   build is viable at all.

## Layout

- `PasswordProtect.Core` (`net8.0`, no WPF) — engines (qpdf / 7z / Office),
  naming, detection, batch orchestration, binary provisioning. Fully headless-
  testable.
- `PasswordProtect.App` (`net8.0-windows`, WPF) — GUI + CLI verbs; the single-file
  publish target; embeds the qpdf/7z payload.
- `PasswordProtect.Tests` (`net8.0`, xUnit) — pure-logic + real encryption
  round-trips.
- `PasswordProtect.Build/Sign.targets` — optional Authenticode signing.

## Manual verification checklist (what CI can't click)

- Launch the exe; drag a PDF and a `.docx`; set a password; **Apply**. (A `.txt` will
  fail — the 7-Zip engine has no binary; see above.)
- Confirm the protected PDF and `.docx` open in Acrobat/**real Microsoft Word** with
  the password. The `.docx` check is the one the test suite cannot do for you.
- Try **Change password** then **Remove password** on those outputs, and confirm the
  result still opens — decryption is unauthenticated, so corruption would be silent.
- Run `--register-context-menu`, right-click a PDF in Explorer, confirm the verb. On a
  machine that also ran the root tool's `install.ps1`, expect **two identically
  labelled "Protect with password" entries** — they are additive, and only the root
  tool's writes an escrow record. `uninstall.ps1` does not remove this app's entry.
