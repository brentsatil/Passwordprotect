# Pilot rollout checklist

A right-sized plan for rolling the tool out to a small practice. No Group
Policy or AD "rings" needed - that's overkill for a handful of PCs. If you grow
to dozens of machines later, see the GPO notes in `docs/ARCHITECTURE.md`.

The goal: prove it works and that recovery works **before** the whole team
relies on it.

## Day 0 - set up and prove recovery (you, ~30 min)

- [ ] Decide the two shared locations (client list + escrow folder). See
      `docs/ADMIN-SETUP.md`.
- [ ] Publish the first `clients.csv` from the master spreadsheet
      (`admin\Publish-Clients.ps1`, or let `setup.ps1 -ClientSource` do it).
- [ ] Run `setup.ps1` on your own PC (Launcher or Install mode). Confirm it ends
      with `Setup complete` and a healthy check.
- [ ] Store the escrow **`.pfx` + its password** in the safe, and make the
      off-site second copy. **Do this before anyone protects a real file.**
- [ ] **Recovery drill:** protect a throwaway test PDF, then recover its
      password from the escrow USB:

      ```powershell
      .\admin\Recover-File.ps1 -PrivateKeyPath E:\curo-escrow.pfx -SourceName test.pdf
      ```

      Confirm the recovered password (on your clipboard) matches. If this
      doesn't work, STOP and fix it - recovery is the safety net.

## Week 1 - two pilot users

- [ ] Set up two willing colleagues (one per mode if you want to try both).
- [ ] Give them `docs/CHEATSHEET.md`.
- [ ] They protect and send real files as part of normal work.
- [ ] Each morning run `admin\Get-AuditSummary.ps1 -Days 1` and glance at it:
      any `fail` outcomes or non-`OK` error codes? Investigate before widening.
- [ ] Collect friction: anything confusing, any client who couldn't open a file.

**Go / no-go before Week 2:** no unresolved failures in the audit summary, both
pilots can protect + send without help, and the recovery drill passed.

## Week 2 - the rest of the team

- [ ] Set up remaining PCs (repeat the setup command per PC).
- [ ] Hand out the cheat sheet; do a 10-minute demo.
- [ ] Keep running the weekly `Get-AuditSummary.ps1 -Days 7` for the first month.

## Ongoing rhythm

| When | Task | How |
|------|------|-----|
| Weekly | Refresh the client list | `admin\Publish-Clients.ps1 -Source <master>` |
| Weekly | Review the audit summary | `admin\Get-AuditSummary.ps1 -Days 7` |
| Twice a year | Recovery drill | protect a test file, recover it from the USB |
| Yearly | Rotate the escrow key | `admin\Rotate-EscrowKey.ps1` (keep old USBs forever) |

## Rollback

If you need to back out on a PC:

- Launcher mode: just stop using the folder (nothing was installed).
- Install mode: run `uninstall.ps1` as admin. It removes the menus and program
  files but **keeps the audit log** (compliance retention). Add `-PurgeAuditLog`
  only when decommissioning a PC, after the audit log is archived.

Protected files already sent to clients keep working regardless - the password
is the DOB and recovery does not depend on the tool staying installed.
