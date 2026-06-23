# FromLan PSD Importer

**Godot 4 插件** — 将 Photoshop PSD 文件的图层导出为 PNG 纹理，并自动生成 Godot Control UI 场景（`.tscn`）。

![Godot 4.2+](https://img.shields.io/badge/Godot-4.2%2B-%23478cbf)
![GDScript](https://img.shields.io/badge/language-GDScript-blue)
![Version](https://img.shields.io/badge/version-2.0-brightgreen)

---

## 功能

- **三种导入模式**
  - `ByLayerAndScene` — 按图层导出 PNG + 生成 Control 场景（`.tscn`）
  - `ByLayer` — 仅按图层导出 PNG
  - `Merged` — 导出单张合并 PNG

- **层级场景生成** — 根据 PSD 图层组（SectionDivider）自动生成嵌套的 Control / Container 节点树

- **UI 节点类型映射** — 通过图层命名约定 `[TypeTag]` 自动将图层映射为对应的 Godot UI 节点（Button、Label、NinePatchRect、VBoxContainer、Panel 等 20+ 种类型）

- **九宫格 (9-Slice) 支持** — `[9Patch]` 标签配合边距参数或 `__9L / __9R / __9T / __9B` 标注图层自动计算 NinePatchRect 边距

- **文字图层解析** — 解析 PSD TySh（Type Tool Engine）数据块，提取文本内容、字体、字号、颜色、对齐等属性，生成 Label 或 RichTextLabel 节点

- **图层蒙版处理** — 支持跳过（Skip）、应用（Apply）或报错（Error）三种策略

- **重复图层处理** — 支持重命名（Rename）、保留首个（KeepFirst）、保留末个（KeepLast）

- **组导出策略** — 支持忽略组（Ignore）、子目录（SubDirectories）、扁平化前缀（Flattened）

- **GBK 编码兼容** — 内置 GBK → UTF-16 转换表，完美支持中文 Photoshop 图层名

- **编辑器停靠面板** — 内置独立 Dock UI，支持手动导入、批量导入和刷新文件列表

- **多语言界面** — 内置英文和中文界面翻译，自动跟随编辑器语言设置

---

## 安装

1. 将 `addons/FromLan_PSD_Importer/` 文件夹复制到你的 Godot 项目的 `addons/` 目录下
2. 在 Godot 编辑器中打开 **项目 → 项目设置 → 插件**
3. 找到 **PSD Scene Importer**，状态设为 **启用**
4. 将 `.psd` 文件放入项目目录，Godot 会自动识别

---

## 使用方法

### 自动导入

将 `.psd` 文件放入项目文件夹，在文件系统面板中选中该文件，在底部的 **导入** 面板中：

1. 选择 **导入模式**（ByLayerAndScene / ByLayer / Merged）
2. 调整各参数（场景生成、九宫格、文字图层处理等）
3. 点击 **重新导入**

### 手动导入

通过编辑器左侧下方的 **PSD Importer** 停靠面板：

1. 面板会自动列出项目中所有 `.psd` 文件
2. 选中一个文件，配置导入参数
3. 点击 **导入** 按钮执行导入

### 图层命名约定

图层名称中使用 `[TypeTag]` 语法来指定生成的节点类型：

| 标签 | 映射节点 |
|------|---------|
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

可以在标签后附加 `key:value` 参数，如 `[Button,text:Click]`、`[Label,text:Hello]`。

---

## 导入参数说明

| 参数 | 说明 |
|------|------|
| **import_mode** | 导入模式：ByLayerAndScene / ByLayer / Merged |
| **layer_name_encoding** | 图层名编码：UTF-8 / GBK（中文 Photoshop 选 GBK） |
| **layer_trim_enabled** | 是否裁剪图层的透明边缘 |
| **layer_mask_handling** | 蒙版处理：Error / Skip / Apply |
| **generate_hierarchy** | 是否根据图层组生成层级 Control 场景 |
| **hierarchy_group_node** | 组映射节点：Control / Panel / PanelContainer |
| **root_anchor_mode** | 根节点锚点：Fixed（像素尺寸）/ FullRect |
| **text_layer_behavior** | 文字层处理：Rasterize（光栅化）/ Label / RichTextLabel |
| **nine_slice_enabled** | 是否启用九宫格检测 |
| **group_export_behavior** | 组导出策略：Ignore / SubDirectories / Flattened |
| **duplicate_handling** | 重复图层处理：Rename / KeepFirst / KeepLast |
| **max_png_dimension** | PNG 最大边长限制（0 = 不限制） |

---

## 架构

```
addons/FromLan_PSD_Importer/
├── plugin.gd                 # EditorPlugin 入口
├── psd_scene_importer.gd     # EditorImportPlugin 子类（导入面板）
├── psd_import_core.gd        # 核心导入管线
├── psd_parser.gd             # PSD 二进制格式解析器（~3600 行）
├── big_endiean_reader.gd     # 大端字节读取工具
├── image_data.gd             # 图层图像数据类
├── layer_tree.gd             # 图层组层级树构建
├── scene_builder.gd          # .tscn 场景文件生成
├── ui_node_mapper.gd         # 节点类型映射
├── nine_slice_processor.gd   # 九宫格边距解析
├── ty_sh_parser.gd           # 文字图层数据解析
├── gbk_encoding.gd           # GBK → UTF-16 转换
├── psd_importer_dock.gd      # 编辑器 Dock 面板
├── plugin_translation.gd     # 多语言支持
├── photoshop_document.gd     # 导入记录 Resource
├── psd_importer_dock.tscn    # Dock 面板场景
└── locales/
    ├── en.tres               # 英文翻译
    └── zh.tres               # 中文翻译
```

---

## 兼容性

- **Godot**: 4.2+
- **渲染器**: GL Compatibility / Forward+ / Mobile
- **语言**: GDScript（纯原生，无 C++ 扩展或外部依赖）
- **PSD 版本**: 兼容 Photoshop CS6 及以上版本（PSB 大文档格式有限支持）

---

## 许可

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
