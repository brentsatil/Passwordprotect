# Curo PDF Protector - staff cheat sheet

Keep this by your desk. One page, everything you need day to day.

## Protecting a PDF

**Drag-and-drop way** (easiest, works everywhere):
1. Drag the PDF (or several) onto **PasswordProtect.exe**
   (or `PasswordProtect.cmd` if you were given the folder version).
2. **One window lists all your files.** Most rows already show the right client,
   matched from the file name. Any row saying **Needs client**: click it, type a
   few letters of the client's name in the box below, pick them from the list.
3. Click **Protect all**. It won't let you until every row has a client. Rows
   turn OK (or FAILED, with the reason) as it works through them - it can pause
   a few seconds per file, which is normal.
4. Double-clicking the exe instead opens a window you can drop files onto.

Need to stop partway? **Cancel** finishes the file it's on, then stops. Anything
already protected is finished properly - nothing is left half-done.

**Right-click way** (if it's installed on your PC):
1. Right-click the PDF in File Explorer.
2. If **Protect with password** is right there in the menu, use it (PCs with
   the modern menu installed show it directly).
   If it isn't: click **"Show more options"** first - or press **Shift+F10**
   instead of right-clicking, which opens that menu directly. Windows 11
   tucks add-in commands under there on other PCs; nothing is broken.
3. Choose **Protect with password** (or **Protect and attach to new email**).
4. Start typing the client's name, pick them from the list, click Protect.

Either way you get a new file next to the original called
`<name>_protected.pdf`. The original is left alone.

## The password

The password **is the client's date of birth**, written as **DDMMYYYY** with no
spaces or slashes. Example: 3 December 1970 -> `03121970`.

When you send the file, tell the client (by phone or SMS - not in the same
email): *"The password is your date of birth, eight digits, day-month-year. For
example 3 December 1970 is 03121970."*

## If something looks wrong

- **"Setup required" / a message about missing settings** - your PC hasn't been
  set up yet, or a shared folder is offline. Tell whoever looks after the tool.
- **Nothing happens / a window flashes and closes** - a report was saved to
  `%LOCALAPPDATA%\CuroPDFProtect\error.log`. Send that file on.
- **"The client list is unavailable or out of date"** - the master list needs
  re-publishing; you can still type a password manually for now.
- **Client says the password doesn't work** - double-check their DOB in the
  client list matches what they gave you. If still stuck, ask an admin to
  recover it (they can, from the escrow record).
- **"Protect with password" isn't in the right-click menu** - on Windows 11
  check under **Show more options** (or press Shift+F10). If it isn't there
  either, this PC hasn't had the right-click menu installed; use drag-and-drop.
- **A blue "Windows protected your PC" screen** the first time you run the exe -
  that's Windows not recognising an in-house tool, not a virus warning. Click
  **More info -> Run anyway**, and tell whoever set it up so they can clear it
  for everyone.
- **Dropped a folder and nothing looked right** - drop the PDFs themselves. To do
  a whole folder, right-click the folder and choose *Protect all files in folder*.
- **"Protect all" is greyed out** - at least one row still says *Needs client*.
  Click that row and search for the client; the button enables itself.
- **A non-PDF got skipped** - the tool is PDF-only. It tells you which files it
  skipped and carries on with the PDFs.
- **"Protect and attach to new email" put the file on my desktop instead** -
  you're on the new Outlook, which the tool can't attach to directly. The file is
  on your desktop, ready to drag into your email.

## Rules of thumb

- Send the file and the password by **different** channels.
- Don't rename `_protected` files before sending - the name is how recovery
  finds them.
- **Check the Client column before clicking Protect all.** The tool only fills
  in a client when the file name clearly identifies one; anything less certain
  is left as *Needs client* with a suggestion for you to confirm. It is still
  your check to make - a file named after the wrong client will be protected
  with the wrong person's date of birth.
