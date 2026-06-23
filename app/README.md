# PasswordProtect — native .NET 8 app

A self-contained Windows desktop app that bulk password-protects and re-keys
documents. It is the native successor to the PowerShell drag-and-drop tool in the
repo root; it reuses the same bundled `qpdf.exe` / `7z.exe` and the same
encryption behaviour, with a real GUI, smart naming, and password editing.

## What it does

- **Bulk protect** many mixed files at once: drag-drop or *Add Files*, type one
  password, click **Apply**. Per-file status, runs in parallel, one bad file
  never stops the rest.
- **Per-type encryption (your choice):**
  - PDF → native AES-256 via qpdf.
  - Word/Excel/PowerPoint → **native ECMA-376 agile encryption** (a real
    password-protected `.docx`/`.xlsx`/`.pptx` that opens in Office), or `.7z`.
  - Anything else → AES-256 `.7z`.
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
qpdf/7z to a hash-verified per-user cache (`%LOCALAPPDATA%\PasswordProtect\bin`).

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

CI (`.github/workflows/app-ci.yml`, windows-latest) runs the tests (incl. real
qpdf/7z/Office round-trips), compiles the WPF app, and verifies the portable exe
publishes on every push.

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
2. **No certificate?** Running the exe from a *trusted internal share* generally
   avoids the "unknown publisher" prompt (files copied from a mapped drive
   usually carry no Mark-of-the-Web). IT can also allowlist it by hash/path in
   AV/SmartScreen.
3. **Buying one is optional** and only worth it if warnings actually appear. A
   standard OV certificate (~$100–300/yr) needs to build SmartScreen reputation;
   an EV certificate gives instant reputation but costs more and needs a hardware
   token.

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

- Launch the exe; drag a PDF, a `.docx`, and a `.txt`; set a password; **Apply**.
- Confirm the protected PDF and `.docx` open in Acrobat/Word with the password,
  and the `.txt` became a password-protected `.7z`.
- Try **Change password** then **Remove password** on those outputs.
- Run `--register-context-menu`, right-click a PDF in Explorer, confirm the verb.
