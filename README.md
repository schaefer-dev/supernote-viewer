<p align="center">
  <img src="docs/images/hero.png" alt="Supernote Viewer: open your Supernote notebooks and marked-up PDFs right on your Mac" width="100%">
</p>

<p align="center">
  <a href="https://github.com/schaefer-dev/supernote-viewer/releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/schaefer-dev/supernote-viewer?label=download&color=333"></a>
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-333">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5-333">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-333"></a>
</p>

Your Supernote syncs `.note` notebooks and `.pdf.mark` annotations to your Mac, but macOS can't open them. These two small apps fix that. Notebooks open with a double-click, preview with Space and can be searched like any other PDF. Everything runs on your Mac: no cloud, no account, no network access.

- **Supernote Viewer** opens notes in its own window, with thumbnails, live reload and a measuring tool.
- **Supernote Preview Bridge** turns notes into PDFs and opens them in Apple's **Preview**, so you keep the tools you already know.

You pick which one opens your files on double-click. Both come with Quick Look.

## Features

### Opens in Preview, with searchable handwriting

Double-click a notebook and it opens in Apple's Preview. Handwriting is drawn as vector strokes from the notebook's own pen data, so it stays crisp at any zoom. Apple's on-device text recognition adds an invisible text layer (English and German), so you can search with ⌘F and select and copy your handwriting. Typed text boxes and marker highlights come through as well. Titles you mark on the Supernote become the PDF's table of contents (View → Table of Contents), so you can jump between sections.

<p align="center"><img src="docs/images/preview.jpg" alt="A Supernote notebook opened in Preview" width="520"></p>

### Quick Look in Finder

Select a `.note` or `.pdf.mark` file and press Space for a full preview without opening any app.

### Supernote Viewer: its own window, with live reload

Marked-up PDFs show your handwriting on top of the original document. There's a thumbnails sidebar (⌥⌘2). When your Supernote syncs a change, the open window updates by itself, so you can keep a notebook open on your Mac while you write on the device.

<p align="center"><img src="docs/images/viewer.jpg" alt="Supernote Viewer showing a PDF with handwritten Supernote annotations" width="640"></p>

### Measure plans to scale

For floor plans and sketches: choose **Calibrate** and drag along a length you know (e.g. `2,23 m`), then choose **Measure** and drag. Hold ⇧ for straight lines; click a line and press ⌫ to delete it. **Export PDF…** saves the measurements as standard PDF annotations. Calibrations and measurements are saved per file. Measuring also works on plain PDFs (Open With → Supernote Viewer, or the Finder Quick Action **Measure in Supernote Viewer**).

## Install

1. Download the **.dmg** from the [latest release](https://github.com/schaefer-dev/supernote-viewer/releases/latest).
2. Open it and drag both apps to **Applications**. The apps are signed, so they should open without any security warnings.
3. Open **Supernote Viewer** once. This turns on the Quick Look extension.
4. Choose which app opens your files. In Finder, select a `.note` file → **Get Info** → **Open with** → pick an app → **Change All…**. Do the same for a `.mark` file.
   - **Supernote Viewer** if you want thumbnails, live reload or measuring.
   - **Supernote Preview Bridge** if you'd rather annotate, sign or print in Preview.

   To try one without changing the default, right-click a file → **Open With**.

<p align="center"><img src="docs/images/open-with.jpg" alt="Finder's Open With menu listing Supernote Preview Bridge and Supernote Viewer" width="520"></p>

If Quick Look previews don't show up, check that **Supernote Quick Look** is turned on under System Settings → General → Login Items & Extensions → Quick Look.

Want to try it before syncing your own notes? Use the files in [`examples/`](examples/).

### How Preview copies work

Preview Bridge opens a generated PDF from `~/Library/Caches/dev.schaefer.SupernoteViewer/`. It's regenerated when the notebook changes. If you edited that copy in Preview and saved it, it's never overwritten; the next render goes to `Name 2.pdf`. To keep an annotated version, use File → Export or Duplicate.

## Compatibility and feedback

Tested with Supernote **Manta** files (format `SN_FILE_VER_20260016`, Chauvet 3.28.42). Other models (Nomad, A5 X, A6 X2) use the same format family and will probably work, but they're untested. If a file from your device doesn't render correctly, please [open an issue](https://github.com/schaefer-dev/supernote-viewer/issues) and, if you can, attach a sample file.

Handwriting recognition is only as good as Apple Vision is on quick handwriting, so expect some misread words in search and in the table of contents.

## Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
./install.sh
```

This builds both apps and installs them to `/Applications`, replacing a copy installed from the DMG. The apps are signed ad-hoc, which is fine on your own Mac. To sign with your Apple Development certificate instead, run `DEVELOPMENT_TEAM=<your team ID> ./install.sh`.

`./release.sh` builds the signed and notarized DMG for a GitHub release. The script prints the one-time setup it needs.

<details>
<summary><b>For developers: project layout and file format notes</b></summary>

### Layout

- `SupernoteKit/`: Swift package with the file parser, RLE decoder, layer compositor, stroke (`TOTALPATH`) parser, vector renderer, handwriting text layer and PDF renderer.
  - `swift test` runs the tests. Tests that use the files in `examples/` always run. Tests that need private sample files in `example_files/` are skipped when those files are missing.
  - `swift run -c release snrender <file> out.pdf [--png outdir] [--dpi n] [--bitmap] [--ocr] [--benchmark [n]]` renders a file from the command line. With `--ocr` it also prints the text layer and the table of contents. With `--benchmark` it renders the file n more times (default 5) after a warm-up and prints total and per-page timings. Use a release build for meaningful numbers.
- `QuickLookPreview/`: the Quick Look extension. It is data-based and returns a PDF built by `PDFRenderer`.
- `Shared/`: the render cache used by both apps.
- `Viewer/`: Supernote Viewer. Its PDFKit window has thumbnails, live reload and measuring. It exports the `.note` and `.mark` file types.
- `Bridge/`: Supernote Preview Bridge. It hands rendered PDFs to Preview. It imports the file types, so it works on its own.
- `project.yml`: the XcodeGen spec. The `.xcodeproj` is generated from it.
- `Viewer/AppIcon.icon`, `Bridge/AppIcon.icon`: the app icons, made for Icon Composer (layers, glass, light-only appearance). Xcode builds the macOS 13–15 images from them.
- `Artwork/`: icon sources. `render.sh` regenerates the icon layers and the `.note`/`.mark` document icons (`Shared/*.icns`) from `artwork.py`. `release.sh` uses `app-icon.swift` for the DMG volume icon, and the README banner uses it too.
- `docs/hero/`: source of the README banner (`render.sh` regenerates it).

### Debugging

- Renderer changes: `snrender` always renders fresh and leaves the apps' cache alone, e.g. from `SupernoteKit/`: `swift run snrender "../examples/Example Titles.note" /tmp/out.pdf --ocr && open /tmp/out.pdf`.
- The Bridge from Xcode: in the SupernotePreviewBridge scheme, Edit Scheme → Run → Arguments, tick the example path (or add your own `.note`/`.mark`) and press Run. Debug builds open it freshly rendered in Preview, with breakpoints working and nothing installed or deleted. Release builds ignore the argument.
- Outside Xcode, `touch file.note` makes the apps render that file again.
- SupernoteKit is compiled with optimization in Debug builds too (`Package.swift`); unoptimized, large notebooks take minutes.

### Stroke data (`TOTALPATH`)

Each page's `TOTALPATH` block holds every stroke, including the device's own rendered outline polygons. Filling those outlines reproduces the device bitmap exactly. See `Strokes.swift` for the record layout.

- Erased strokes stay in the file, flagged −4.
- Surviving pieces of erased strokes are stored as outline-only fragments.
- Eraser strokes have color 255.

A per-layer coverage check falls back to the bitmap if the strokes don't account for the layer's ink.

### Titles

The footer lists each title as `TITLE_<page><y><x>` (older files: `TITLE_<page><y>`), pointing to a block with `TITLERECT`, `TITLELEVEL` and a bitmap of the title. The table of contents labels each title with the text layer words inside `TITLERECT`, so it needs no extra recognition pass. Without the text layer (Quick Look) there is no table of contents.

### Credits

Format notes come from [supernotelib](https://github.com/jya-dev/supernote-tool) and [GoSNare](https://github.com/alefaraci/GoSNare).

</details>

## License

[MIT](LICENSE). Not affiliated with Ratta or Supernote.

## iPhone and iPad (iOS 26+)

The native online reader is in `ViewerIOS/`. It supports Dropbox browsing/opening,
opening documents shared from other apps, PDFKit reading/search, a page grid and
titles, PDF export, recents and local Dropbox favorites. Star whole documents from
document lists, or bookmark the current page from the reader; bookmarks show the
page's handwritten title and number. Home provides quick access, and the full
Favorites list supports manual ordering. Favoriting does not download documents
automatically. It displays a complete preview before handwriting OCR.
See [iOS setup and validation](docs/ios-implementation.md) for configuration,
build commands and outstanding real-account/physical-device checks. Offline
pinning and synchronization remain [later roadmap work](docs/ios-port-plan.md).
