# Risk Register

Read this before approving the project. Every risk here needs a decision:
**accept**, **mitigate**, or **avoid (don't build it this way)**.

Ordered roughly by severity for a small business.

---

## 1. Lost password = permanently lost data

AES-256 and PDF AES-256 are not recoverable. If a user forgets their password,
the file is gone. No vendor, no helpdesk, no forensic tool will get it back.

**Mitigation options**

- **Key escrow (recommended).** On install, generate an admin RSA keypair.
  Each protected file also carries a copy of its random file-key encrypted
  to the admin public key. IT can unlock any file with the admin private
  key. Requires secure custody of the admin private key (HSM / offline
  backup / break-glass procedure).
- **Shared business password.** One password per team, stored in the
  business password manager. Simpler, weaker — any leak compromises
  everything.
- **Accept the loss.** Publish a written "we cannot recover your files"
  policy. Users must keep their own copies.

**Decision required:** see `DECISIONS.md` item 1.

---

## 2. Password theft

Passwords can leak via:

- Keyloggers and clipboard grabbers on the user's machine.
- Shoulder-surfing.
- Passwords passed on a command line appear in `Get-Process`, Sysmon
  event 1, `ConsoleHost_history.txt`, and Scheduled Task definitions.
- Passwords written into log files "just for debugging".
- Passwords stuck in PowerShell transcription (`Start-Transcript`).

**Mitigation (all in scope for v1)**

- WPF `PasswordBox` → `SecureString` only.
- Pass the password to `qpdf` / `7z` via **stdin** or an ephemeral env var,
  never as an argument.
- Disable PowerShell history for the protect script
  (`Set-PSReadLineOption -HistorySaveStyle SaveNothing` within the script's
  runspace).
- Audit log captures `filepath`, `user`, `timestamp`, `outcome` — never the
  password.

---

## 3. Original plaintext left on disk

Creating `secret.pdf.7z` next to `secret.pdf` and deleting `secret.pdf`
with `Remove-Item` leaves the plaintext recoverable by forensic tools.
On SSDs with TRIM the problem is partially mitigated but not eliminated.

**Mitigation**

- `--delete-original` is **opt-in** via a checkbox in the prompt.
- When enabled, overwrite the file (best-effort, with an honest warning
  that SSD wear-levelling defeats this) before deletion. `SDelete` is a
  reasonable choice.
- Default to **keep original** for safety. Users who want the plaintext
  gone tick the box.

---

## 4. Weak user-chosen passwords

PDF user-passwords and 7z passwords are both offline-crackable. A 6-char
password falls to a GPU rig in seconds.

**Mitigation**

- Enforce minimum length (proposed: 12) and complexity in the prompt.
  Reject weak passwords before encryption.
- Offer an "insert generated password" button that writes a strong
  password to the prompt and copies it to the clipboard for the user to
  paste into their password manager.
- Always use AES-256 variants. Never legacy RC4 / 40-bit PDF crypto.
  Never ZipCrypto.

---

## 5. ZIP encryption footguns

Default ZIP uses ZipCrypto, which is broken (known-plaintext attack —
see Biham & Kocher, 1994). Anything that says "password-protected zip"
without specifying AES-256 is suspect.

**Mitigation**

- Use `.7z` format (`-t7z`) with `-mhe=on` (encrypt filenames too) and
  AES-256 (7-Zip's default for 7z).
- If a user specifically needs `.zip` for compatibility, use
  `-tzip -mem=AES256` and document the compatibility caveat (stock
  Windows Explorer cannot open AES-encrypted zips; the recipient will
  need 7-Zip).

---

## 6. Dependency supply chain

`qpdf.exe` and `7z.exe` are bundled. A malicious or outdated binary
compromises every file the tool touches.

**Mitigation**

- Pin to specific upstream versions.
- Verify SHA-256 of each binary at install time against a hash baked
  into `install.ps1`.
- Refresh versions quarterly; re-sign the installer.
- Ship via your existing software deployment channel (Intune / SCCM /
  GPO), not an ad-hoc download link.

---

## 7. Context-menu deployment on locked-down endpoints

- Per-user `HKCU\Software\Classes\*\shell` entries are invisible to other
  users on a shared machine.
- `HKLM` entries need admin rights to install and apply machine-wide.
- Some corporate AppLocker / Windows Defender Application Control
  policies block unsigned scripts entirely.

**Mitigation**

- Package as an MSI, Authenticode-sign both the MSI and the PowerShell
  scripts with the business code-signing cert.
- Deploy to a pilot group of 3–5 users before a full rollout.
- Have an uninstall path ready (`uninstall.ps1` and MSI uninstall).

---

## 8. Automation has a large blast radius

A watched folder that auto-encrypts everything dropped into it behaves
exactly like stage-one ransomware from an EDR's perspective. It will
trigger Defender / CrowdStrike / SentinelOne alerts.

**Mitigation**

- Watched paths live in a config file; the service refuses to watch a
  path not on the allowlist.
- Dry-run mode (log what would be encrypted, don't touch the file) for
  onboarding a new watch path.
- Per-file rate limit (e.g. max 60 files/minute) so a misconfiguration
  can't trash a whole fileserver before someone notices.
- Coordinate with whoever runs the EDR to whitelist the signed
  executable path before go-live.

---

## 9. Key management doesn't scale

Thirty staff picking their own password per file is thirty single points
of failure and thirty retrieval headaches.

**Mitigation (long-term, beyond v1)**

- Certificate-based encryption: each user has a PFX, files are encrypted
  to a list of recipient certs. No shared secret.
- Or adopt Microsoft Purview / Azure Information Protection if the
  business is on M365 — stop rolling our own for anything sensitive.

V1 ships with "user picks a password + optional admin escrow key". If
adoption grows past ~20 users, revisit.

---

## 10. Compliance and legal exposure

For regulated data (PHI under HIPAA, PCI-DSS cardholder data,
UK GDPR special category data, legal privilege, HR records), a
homebrewed "zip with a password" is unlikely to satisfy an auditor
even if the crypto is sound. Auditors want managed, logged,
revocable, recipient-authenticated protection.

**Mitigation**

- Use Microsoft Purview / AIP, S/MIME email, or BitLocker-to-go for
  portable media — recognised standards — for regulated workloads.
- Scope this tool explicitly to **non-regulated convenience protection**
  (e.g. "emailing a quote to a client"). Put that scope in the
  acceptable-use note users see on first run.

---

## 11. Support load

Every deployed tool generates tickets. Expect:

- "I forgot the password."
- "The recipient can't open the `.7z`."
- "Windows says this file is unsafe."

**Mitigation**

- Published KB article with the three answers above.
- Admin-recovery workflow (escrow key) for the first one.
- Installer bundles the 7-Zip download link to send to recipients.
- Authenticode signature on everything to satisfy SmartScreen.

---

## 12. Over-blocking productivity

If the tool is slow, the prompt is fiddly, or the UX is ugly, staff
will bypass it and send plaintext files instead.

**Mitigation**

- Prompt must open in under 300 ms.
- Defaults must be safe so the user only has to type the password.
- "Recently used password" — **no**. That defeats the point.
- "Use password from team password manager" integration — possible v2.
