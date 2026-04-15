# Document Password Protection — Procedure

*(One-page procedure for inclusion in the Curo Financial Services Cyber
Security Policy. Approved by Brent and Ian, effective [DATE].)*

## Purpose

All advice documents and client correspondence sent to clients by email or
file-transfer must be protected against casual interception. This procedure
describes how Curo staff apply password protection to PDF and other client
documents using the **Curo PDF Protector** tool.

## Scope

Applies to all Curo Financial Services staff and contractors using
Curo-managed Windows devices to send documents containing personal or
financial client information.

Out of scope: health (PHI) and payment-card (PCI) data. These are not
produced or transmitted by Curo Financial Services.

## Standard

1. **Cipher.** All protected PDFs use AES-256 (via `qpdf`). All protected
   non-PDF files are placed in a `.7z` archive with AES-256 and encrypted
   headers (via `7-Zip`). Legacy ciphers (RC4, 40-bit, ZipCrypto) are not
   used.
2. **Password convention.** Client documents are protected with the client's
   date of birth in `DDMMYYYY` format (no separators, zero-padded). Example:
   a client born 12 March 1970 receives a document protected with `12031970`.
3. **Client-facing wording.** The covering email/letter must include the
   standard boilerplate: *"This document is password protected. Your
   password is your date of birth in `DDMMYYYY` format (e.g. `12031970`)."*
4. **Exceptions.** Where a document is not associated with a specific client
   (e.g. internal templates, marketing packs), a manually entered password
   of at least 10 characters across 3 character classes is used instead.
5. **Escrow.** Every protected file's password is wrapped with the Curo
   RSA escrow public key and stored as a per-file sidecar on the file
   server. The private key is held on a USB in the office safe, with a
   second copy at Ian's home safe. Recovery is performed only by Brent or
   Ian, via `admin\Recover-File.ps1`, and is audit-logged.
6. **Audit retention.** The tool's audit log is retained for seven (7) years
   in line with Corps Act s.988A and ASIC RG 104.
7. **Original files.** By default the tool creates a `_protected` copy
   alongside the original. The original is retained unless the user
   explicitly opts to delete it.
8. **Off-network.** Staff working from a laptop that cannot reach the file
   server cannot use the tool; the tool refuses to protect a file if the
   escrow record cannot be written. Staff must return to the office LAN or
   VPN-in before protecting client documents.

## Residual risk (accepted)

DOB-derived passwords are materially weaker than random passwords — roughly
30,000 plausible adult DOBs. They are used because clients are expected to
type them on mobile devices with no password manager. Mitigation: (a) this
control is document-level, not data-store level; (b) files are typically
transmitted over TLS-protected email; (c) recovery is via escrow, not the
password. This trade-off is accepted in writing by the directors.

## Change control

Any change to this procedure, the tool's settings, or the escrow keypair
must be approved by a director, recorded in the audit log via the relevant
admin script, and reflected in the next Cyber Security Policy review cycle.

---

**Version 1.0 — approved [DATE]**
