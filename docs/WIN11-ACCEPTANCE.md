# Windows 11 acceptance - run this once before the team gets it

CI proves a great deal (escrow, encryption, fail-closed, config lifecycle, the
XAML loads, concurrent protects, the archive round-trip) but it runs on a
Windows **Server** image with **no interactive desktop**. Three things are
therefore impossible to prove there and must be checked by a human, once, on a
real Windows 11 PC:

1. a window actually appears and is usable,
2. Explorer shows the verb where a person can find it,
3. Windows lets the exe run at all (SmartScreen / Smart App Control).

Budget 20 minutes. Do it on the PC you intend to hand out from, then again on
the first teammate's PC.

---

## 0. Before you start

| Check | How | Expected |
|---|---|---|
| Windows build | `winver` | Windows 11 (any current build) |
| .NET Framework 4.8 present | `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release` | >= 528040 (ships with Win11) |
| Smart App Control | Windows Security -> App & browser control | Note whether it is **On**, **Evaluation** or **Off** |

> If Smart App Control is **On**, an unsigned `PasswordProtect.exe` will be
> blocked no matter what else you do, and `Unblock-File` will not help. Stop
> here and sort out signing (`docs\DECISIONS.md` #14) before rolling out.

---

## 1. The exe runs at all

- [ ] Copy `PasswordProtect.exe` to the PC the way staff will actually get it
      (from the share - not built locally, or you will not see what they see).
- [ ] Double-click it.
- [ ] **If you get a blue "Windows protected your PC":** that is Mark-of-the-Web
      plus an unknown publisher. Click *More info -> Run anyway* to continue,
      then fix it centrally with `Unblock-File` on the shared copy and/or by
      adding the share to Local intranet. Re-test from a second account.
- [ ] The drop window appears. **No console window flashes up behind it.**

## 2. Setup, on a real desktop

- [ ] `PasswordProtect.exe --setup`, answer the prompts.
- [ ] It **prompts** for the escrow `.pfx` password rather than taking it on the
      command line (deliberate - argv is visible in the process list).
- [ ] It ends with `Setup complete` and a healthy check.
- [ ] The console stays open long enough to read, and closes on Enter.
- [ ] **Second and later PCs:** the escrow step says
      `Adopted the existing deployment escrow certificate (...)`.
      If it says *generated* instead, STOP - that PC is about to write files
      your recovery USB cannot open.

## 3. The dialogs (the part CI cannot see)

- [ ] Drag **one** PDF onto the exe. The client picker appears.
- [ ] Type a few letters of a client's surname - the list filters as you type.
- [ ] Pick a client, click **Protect**. `<name>_protected.pdf` appears alongside.
- [ ] Open it in Acrobat/Edge; the client's DOB as `DDMMYYYY` opens it.
- [ ] In business mode the manual-password box is hidden **and** a line of text
      explains that the client's DOB will be used. (If the box is simply gone
      with no explanation, that is the bug fixed in Phase C - you are on an old
      build.)
- [ ] Drag **three** PDFs at once: three pickers appear one after another, then
      one summary. The second and third dialogs must actually appear - this is
      the classic PowerShell-WPF trap and has no automated coverage.
- [ ] Drag a **folder** onto the exe: you get a message telling you to drop the
      PDFs themselves, **not** silence.
- [ ] Cancel a picker: nothing is written, no error.

## 4. Explorer integration

Which of the two blocks applies depends on what was installed on this PC.

**A. Legacy verbs only (Install mode, no modern-menu package):**

- [ ] Right-click a PDF. **Expect NOT to see the verb in the first menu** -
      without the modern package, Windows 11 puts add-in commands under
      **Show more options**.
- [ ] Click *Show more options* (or press **Shift+F10** instead of
      right-clicking): **Protect with password** is there.
- [ ] It works, and no console window flashes.
- [ ] Right-click a folder -> **Protect all files in folder** works.
- [ ] Confirm staff have been told about *Show more options*, or they will
      report the tool as "not installed". `docs\CHEATSHEET.md` covers it.

**B. Modern-menu package installed (`shellext\Install-ShellExt.ps1`):**

- [ ] Right-click a PDF: **Protect with password** is in the MAIN (first)
      menu - no *Show more options* needed.
- [ ] Select a PDF **plus** any non-PDF file and right-click: the entry is
      greyed out (the tool is PDF-only by design).
- [ ] Clicking it opens the same client picker as drag-and-drop, and no
      console window flashes.
- [ ] If Install mode is also present, the legacy entries still exist under
      *Show more options* - both run the identical tool; that is expected,
      not a duplicate install.

## 5. Failure paths behave

- [ ] Rename the client list on the share, run the tool: you get a clear
      message, not a silent exit. Put it back.
- [ ] Point `escrow_dir` at a nonexistent share and protect a file: it refuses,
      says `ESCROW_OFFLINE`, and **no** `_protected` file is left behind. Put it
      back. (This is the guarantee that a protected file always has a recovery
      record - worth seeing once with your own eyes.)
- [ ] `PasswordProtect.exe --diagnose` runs and reports ExecutionPolicy scopes,
      LanguageMode, and which `settings.json` is LIVE.

## 6. Recovery drill - do not skip

- [ ] Protect a throwaway PDF.
- [ ] On the admin PC, with the escrow USB:
      `.\admin\Recover-File.ps1 -PrivateKeyPath E:\curo-escrow.pfx -SourceName test.pdf`
- [ ] The recovered password matches the DOB.
- [ ] **Do this from a PC that ADOPTED the key, not the one that generated it.**
      That is the check that proves the whole team shares one escrow key.

## 7. Multi-user, if any PC is shared

- [ ] Log in as a second user on a PC where someone else ran setup.
- [ ] That user runs `PasswordProtect.exe --setup` (per-user config is expected).
- [ ] They can protect a file - in particular the audit log accepts their write.
      If they are blocked here, the ACL step in setup did not take; see
      `docs\ADMIN-SETUP.md`.

---

## Sign-off

| Item | Result | Who | Date |
|---|---|---|---|
| Exe runs (SmartScreen cleared) | | | |
| Setup + adopted escrow key | | | |
| Dialogs, incl. 3-file batch | | | |
| Explorer verb found (main menu, or under Show more options) | | | |
| Fail-closed proven | | | |
| Recovery drill from an adopting PC | | | |

Anything unchecked is a rollout blocker, not a nice-to-have. The recovery drill
in particular: everything else is convenience, but if recovery does not work you
are one forgotten password away from losing a client record.
