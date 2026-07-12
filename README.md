# IFC Quick Look

English | [日本語](README-ja.md)

A macOS Quick Look extension that previews .ifc (BIM / Industry Foundation Classes) files with the spacebar in Finder.
Native implementation with [web-ifc](https://github.com/ThatOpen/engine_web-ifc) (compiled to a native static library) + RealityKit — no WebView, no intermediate file conversion.

- Drag to orbit, pinch or two-finger scroll to zoom, Shift+drag to pan
- Progressive loading: geometry appears within a second, streams in as it parses
- Supports IFC2x3 / IFC4 / IFC4x3, macOS 15+ (Apple Silicon)
- Broken or unsupported files show an explicit error message

## Install (Homebrew)

```bash
brew install trapple/tap/ifc-quicklook
open /Applications/IFCQuickLook.app   # first time only: registers the Quick Look extension
```

If existing .ifc files don't preview (they were indexed before install), reimport them:

```bash
mdimport <folder-with-ifc-files>
```

## Performance

Measured with `ifcql-bench` (Release, Apple Silicon):

| File | Size | Parse | Triangles | Peak memory |
|---|---|---|---|---|
| schependomlaan.ifc (IFC2X3) | 47 MB | 0.5 s | 262,589 | 211 MB |
| S_Office (IFC2X3) | 30 MB | 2.3 s | 1,169,931 | 361 MB |
| ISSUE_098 (IFC2X3) | 70 MB | 6.3 s | 1,645,196 | 611 MB |

## Large files

Quick Look extension processes are constrained by the OS (they slow down heavily past ~1 GB memory footprint). To keep the spacebar experience instant, the preview **truncates parsing after 3 seconds or 800 MB**, shows what it has, and displays a "⚠ N elements omitted" notice.

For the full model, open the file with the bundled viewer app (no limits — a 122 MB / 2.8M-triangle model loads in ~18 s):

Finder → right-click → Open With → IFCQuickLook

## Build from source

Requirements: macOS 15+ (Apple Silicon) / Xcode / cmake / xcodegen (`brew install cmake xcodegen`)

```bash
make install   # submodules → build web-ifc → xcodegen → xcodebuild → copy to /Applications → register
```

If previews don't show up, try `make reset` (resets the qlmanage cache) and `killall Finder`.
Still nothing? Check the registration with `pluginkit -m | grep IFCPreview`.

## Development

```bash
make test      # unit tests
make ql        # open a preview directly via qlmanage -p (bundled fixture)
```

Design notes (in Japanese): `.claude/specs/2026-07-12-ifc-quicklook-design.md`

## License

[MIT](LICENSE) for this project. The distributed binary embeds compiled code from
[web-ifc](https://github.com/ThatOpen/engine_web-ifc) (MPL-2.0); its source is available
upstream and via the pinned submodule at `vendor/web-ifc`.
