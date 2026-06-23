[中文文档](README_zh.md)

# FromLan PSD Importer

A **Godot 4 plugin** that exports Photoshop PSD layers to PNG textures and auto-generates Godot Control UI scenes (`.tscn`).

![Godot 4.2+](https://img.shields.io/badge/Godot-4.2%2B-%23478cbf)
![GDScript](https://img.shields.io/badge/language-GDScript-blue)
![Version](https://img.shields.io/badge/version-2.0-brightgreen)

---

## Features

- **Three Import Modes**
  - `ByLayerAndScene` — Export per-layer PNGs + generate a Control scene (`.tscn`)
  - `ByLayer` — Export per-layer PNGs only
  - `Merged` — Export a single merged PNG

- **Hierarchical Scene Generation** — Auto-generate nested Control / Container node trees from PSD layer groups (SectionDivider)

- **UI Node Type Mapping** — Map layers to Godot UI nodes via `[TypeTag]` naming conventions (20+ node types: Button, Label, NinePatchRect, VBoxContainer, Panel, etc.)

- **9-Slice Support** — `[9Patch]` tags with margin parameters or `__9L / __9R / __9T / __9B` companion layers for automatic NinePatchRect margin calculation

- **Text Layer Parsing** — Parse PSD TySh (Type Tool Engine) data blocks, extracting text content, font family, font size, color, alignment, and more, generating Label or RichTextLabel nodes

- **Layer Mask Handling** — Three strategies: Skip, Apply, or Error

- **Duplicate Layer Handling** — Rename, KeepFirst, or KeepLast

- **Group Export Strategies** — Ignore groups, SubDirectories (nest in subdirectories), or Flattened (prefix filenames)

- **GBK Encoding Compatibility** — Built-in GBK → UTF-16 lookup table for full Chinese Photoshop layer name support

- **Editor Dock Panel** — Built-in dock UI for manual import, batch import, and file list refresh

- **i18n Support** — Built-in English and Chinese translations that follow the editor language setting

---

## Installation

1. Copy the `addons/FromLan_PSD_Importer/` folder into your Godot project's `addons/` directory
2. In the Godot editor, go to **Project → Project Settings → Plugins**
3. Find **PSD Scene Importer** and set the status to **Enabled**
4. Place `.psd` files in your project directory — Godot will auto-detect them

---

## Usage

### Auto Import

Place `.psd` files in your project folder, select the file in the FileSystem dock, and in the **Import** dock at the bottom:

1. Choose the **Import Mode** (ByLayerAndScene / ByLayer / Merged)
2. Adjust parameters (scene generation, 9-slice, text layer behavior, etc.)
3. Click **Reimport**

### Manual Import

Use the **PSD Importer** dock panel on the left side of the editor:

1. The panel automatically lists all `.psd` files in the project
2. Select a file and configure import parameters
3. Click **Import** to execute

### Layer Naming Convention

Use `[TypeTag]` syntax in layer names to specify the generated node type:

| Tag | Mapped Node |
|------|-------------|
| `[Button]` | `Button` |
| `[Label]` | `Label` |
| `[Panel]` | `Panel` |
| `[PanelContainer]` | `PanelContainer` |
| `[Texture]` / `[TextureRect]` | `TextureRect` |
| `[9Patch]` / `[NinePatch]` / `[NinePatchRect]` | `NinePatchRect` |
| `[VBox]` / `[VBoxContainer]` | `VBoxContainer` |
| `[HBox]` / `[HBoxContainer]` | `HBoxContainer` |
| `[Margin]` / `[MarginContainer]` | `MarginContainer` |
| `[Grid]` / `[GridContainer]` | `GridContainer` |
| `[Scroll]` / `[ScrollContainer]` | `ScrollContainer` |
| `[ColorRect]` | `ColorRect` |
| `[VSlider]` | `VSlider` |
| `[HSlider]` | `HSlider` |
| `[Progress]` / `[ProgressBar]` | `ProgressBar` |
| `[RichText]` / `[RichTextLabel]` | `RichTextLabel` |
| `[CheckBox]` | `CheckBox` |
| `[LineEdit]` | `LineEdit` |
| `[TextEdit]` | `TextEdit` |
| `[HSeparator]` | `HSeparator` |
| `[VSeparator]` | `VSeparator` |

Additional `key:value` parameters can follow the tag, e.g. `[Button,text:Click]`, `[Label,text:Hello]`.

---

## Import Parameters

| Parameter | Description |
|-----------|-------------|
| **import_mode** | Import mode: ByLayerAndScene / ByLayer / Merged |
| **layer_name_encoding** | Layer name encoding: UTF-8 / GBK (choose GBK for Chinese Photoshop) |
| **layer_trim_enabled** | Whether to trim transparent edges from layers |
| **layer_mask_handling** | Mask handling: Error / Skip / Apply |
| **generate_hierarchy** | Whether to generate hierarchical Control scenes from layer groups |
| **hierarchy_group_node** | Group mapping node: Control / Panel / PanelContainer |
| **root_anchor_mode** | Root node anchor mode: Fixed (pixel size) / FullRect |
| **text_layer_behavior** | Text layer handling: Rasterize / Label / RichTextLabel |
| **nine_slice_enabled** | Enable 9-slice detection |
| **group_export_behavior** | Group export strategy: Ignore / SubDirectories / Flattened |
| **duplicate_handling** | Duplicate layer handling: Rename / KeepFirst / KeepLast |
| **max_png_dimension** | Maximum PNG side length limit (0 = no limit) |

---

## Architecture

```
addons/FromLan_PSD_Importer/
├── plugin.gd                 # EditorPlugin entry point
├── psd_scene_importer.gd     # EditorImportPlugin subclass (Import dock)
├── psd_import_core.gd        # Core import pipeline
├── psd_parser.gd             # PSD binary format parser (~3600 lines)
├── big_endiean_reader.gd     # Big-endian binary reader utility
├── image_data.gd             # Layer image data class
├── layer_tree.gd             # Layer group hierarchy builder
├── scene_builder.gd          # .tscn scene file generator
├── ui_node_mapper.gd         # Node type mapping
├── nine_slice_processor.gd   # 9-slice margin resolver
├── ty_sh_parser.gd           # Text layer data parser
├── gbk_encoding.gd           # GBK → UTF-16 converter
├── psd_importer_dock.gd      # Editor dock panel logic
├── plugin_translation.gd     # i18n support
├── photoshop_document.gd     # Import record Resource
├── psd_importer_dock.tscn    # Dock panel scene
└── locales/
    ├── en.tres               # English translations
    └── zh.tres               # Chinese translations
```

---

## Compatibility

- **Godot**: 4.2+
- **Renderers**: GL Compatibility / Forward+ / Mobile
- **Language**: Pure GDScript — no C++ extensions or external dependencies
- **PSD version**: Compatible with Photoshop CS6 and later (PSB large document format has limited support)

---

## License

MIT License

Copyright (c) 2024 FromLan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
