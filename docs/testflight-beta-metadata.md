# TestFlight beta metadata

Replace the bracketed maintainer fields in App Store Connect. Do not put private
contact details in Git.

## Beta description

Snip Snap is a small library for text and attachments. The iPhone and iPad app
uses the same core library as the Mac app. iCloud sync is optional and off until
the user enables it.

## What to test

- Create, edit, copy, share, move, and delete text snips.
- Add a local attachment and open it again.
- Save text, a link, and a file through the Share extension.
- Turn iCloud sync on, then check that a text snip and attachment reach another
  signed-in device.
- Turn iCloud sync off and check that the local library remains usable.

## Review notes

Snip Snap has no account or login of its own. iCloud sync is optional. Open
Settings and turn on iCloud Sync to test it. The app stores synced records in
the tester's private CloudKit database. The Share extension appears as **Save
to Snip Snap** in the system Share sheet.

The review contact and feedback email are maintained in App Store Connect:

- Feedback email: [maintainer input]
- Review contact: [maintainer input]

No demo login is needed.
