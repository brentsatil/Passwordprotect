# Curo PDF Protector - staff cheat sheet

Keep this by your desk. One page, everything you need day to day.

## Protecting a PDF

**Right-click way** (if it's installed on your PC):
1. Right-click the PDF in File Explorer.
2. Choose **Protect with password** (or **Protect and attach to new email**).
3. Start typing the client's name, pick them from the list, click Protect.

**Drag-and-drop way** (the launcher):
1. Drag the PDF (or several) onto **PasswordProtect.cmd**.
2. For each file, pick the client from the list, click Protect.

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

## Rules of thumb

- Send the file and the password by **different** channels.
- Don't rename `_protected` files before sending - the name is how recovery
  finds them.
- One PDF per client - the tool asks you to confirm the client for each file.
