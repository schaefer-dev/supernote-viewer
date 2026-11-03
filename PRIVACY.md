# Privacy Policy — Supernote Viewer

_Last updated: 1 November 2026_

Supernote Viewer for iPhone and iPad (the "app") displays Supernote notebooks
(`.note`) and annotated PDFs (`.mark` with their original PDF) on your device.
This policy explains what data the app handles. In short: **the developer
collects no data at all.**

## What the app does not do

- It has no user accounts, servers or backend of its own.
- It contains no analytics, advertising, tracking or crash-reporting services.
- It does not send your documents, account information or usage data to the
  developer or to any third party.

## Dropbox

If you choose to connect Dropbox, you sign in on Dropbox's own page and grant
the app **read-only** access. The app then communicates directly between your
device and Dropbox to:

- read your account name and identifier, shown in Settings;
- list folders and file details (names, sizes, modification dates, revisions);
- download the documents you open or sync.

The app never changes, uploads or deletes anything in your Dropbox. The sign-in
credentials (OAuth tokens) are stored in the iOS Keychain on your device by the
official Dropbox SDK. Your use of Dropbox is governed by
[Dropbox's privacy policy](https://www.dropbox.com/privacy).

## Data stored on your device

To work offline and reopen documents quickly, the app keeps on your device only:

- rendered, searchable PDFs of documents you opened or synced;
- cached handwriting-recognition results;
- your recent documents, reading positions, chosen library folder and the
  connected Dropbox account's name and identifier.

Saved documents are excluded from iCloud backup. Handwriting recognition uses
Apple's on-device Vision framework.

You can remove downloaded documents at any time in **Settings → Remove
Downloaded Documents**. **Disconnect Dropbox** removes the account's sign-in,
recents, library folder and downloaded documents from the device. Deleting the
app removes all of its data. None of these actions affect the files in your
Dropbox.

## Files you import

Documents you open from the Files app are copied into a temporary area for
viewing and are not kept after the session.

## Children

The app does not knowingly collect any personal information from anyone,
including children.

## Changes

Changes to this policy will be published in this file, with an updated date.

## Contact

Questions about this policy: open an issue at
<https://github.com/schaefer-dev/supernote-viewer/issues>.
