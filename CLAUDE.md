# Supernote Viewer

Native macOS viewer and Quick Look extensions for Supernote `.note` notebooks and `.mark` annotations. The Swift package in `SupernoteKit` parses and renders saved tablet files; it does not write notebook binaries.

## Related project: Markdown Import

The companion tablet plugin lives at [`../supernote_markdown_plugin`](../supernote_markdown_plugin). Read its [CLAUDE.md](../supernote_markdown_plugin/CLAUDE.md) and [README.md](../supernote_markdown_plugin/README.md) when working on imported native text, formatting, coordinates or notebook compatibility.

- The plugin creates editable text boxes and notebook pages through the official on-device Supernote SDK. This project reads the resulting saved notebooks on macOS.
- Keep native text-box semantics and file-format assumptions consistent across both projects. Tablet plugin coordinates and saved notebook canvas coordinates can differ; never assume an identical scale.
- Use synthetic, tablet-generated fixtures for shared compatibility checks. Do not commit personal notebooks or Obsidian content.
- Changes to imported text rendering require checking the plugin's device acceptance checklist and this project's parser/PDF renderer. Preserve existing handwriting rendering and bitmap fallbacks.
- Do not introduce direct `.note` binary rewriting here as an import shortcut.

## Development

- See [README.md](README.md) for build instructions and architecture.
- Core checks: `cd SupernoteKit && swift test`.
- Render a saved fixture: `cd SupernoteKit && swift run snrender /absolute/path/example.note /tmp/example.pdf`.
- The companion plugin runs `npm run typecheck`, `npm test`, and `npm run build`. Its tablet/save/restart/sync checks require an actual device and must be reported separately from desktop tests.
