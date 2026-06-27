# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- **Open in Godot editor** — 用 Godot 4.x 打开 `project.godot` 即可加载插件
- **Plugin 路径** — `addons/FromLan_PSD_Importer/`，编辑 GDScript 后无需构建，在 Godot 编辑器中重新加载插件即可生效
- **翻译文件** — `addons/FromLan_PSD_Importer/locales/`，编辑 `.tres` 后需重新加载插件
- **Python 子项目** — `psd-tools/` 有独立的 CLAUDE.md；该库作为上游依赖被 `.gitignore` 忽略，一般不需修改

## 代码架构

插件将 PSD 文件导入为 PNG 纹理 + 可选的 Godot Control 场景 (`.tscn`)。纯 GDScript 实现，兼容 Godot 4.2+。

### 导入流水线

```
PSD 文件
  → psd_parser.gd         二进制解析 (BigEndianReader)
  → psd_import_core.gd    导入编排 (重名处理, PNG 导出, 图层树构建)
    → layer_tree.gd        将扁平图层构建为层次树
    → ui_node_mapper.gd    [TypeTag] 命名约定 → Godot 节点类型
    → nine_slice_processor.gd  九宫格边距解析
    → ty_sh_parser.gd      PSD 文字引擎数据解析
    → scene_builder.gd     生成 .tscn 场景文件
  → PhotoshopDocument     导入记录 (Resource)
```

### 关键文件

| 文件 | 职责 |
|------|------|
| `plugin.gd` | EditorPlugin 入口，注册导入器 + Dock 面板 |
| `psd_scene_importer.gd` | EditorImportPlugin，定义 20+ 导入选项 |
| `psd_import_core.gd` | **核心编排** — PNG 导出、场景生成、整个导入流程 |
| `psd_parser.gd` | **最大的文件** (~1000行) — PSD 二进制格式解析器 |
| `big_endiean_reader.gd` | 大端二进制读取工具类 |
| `layer_tree.gd` | 用 SectionDivider 标记构建层次图层树 |
| `scene_builder.gd` | 生成 flat 或 hierarchical 模式的 .tscn 文件 |
| `ui_node_mapper.gd` | 通过 `[TypeTag]` 命名约定映射到 20+ Godot 节点类型 |
| `nine_slice_processor.gd` | 从附加属性或 companion 图层解析九宫格边距 |
| `ty_sh_parser.gd` | 解析 PSD Type Tool Engine 数据块 (字体、颜色、对齐等) |
| `gbk_encoding.gd` | GBK → UTF-16 转换，用于中文 PSD 图层名 |
| `psd_importer_dock.gd` | Dock 面板 UI — PSD 文件列表、选项面板、批量导入 |
| `psd_importer_dock.tscn` | Dock 面板场景布局 |
| `plugin_translation.gd` | 中英文 TranslationDomain 管理 |

### 三种导入模式

1. **ByLayerAndScene** — 导出每层 PNG + 生成 Control 场景
2. **ByLayer** — 只导出每层 PNG
3. **Merged** — 导出合并后的单张 PNG

### 命名约定

图层名中的 `[TypeTag]` 语法用于指定生成的 Godot 节点类型：
- `[Button]`, `[Label]`, `[NinePatchRect]`, `[VBoxContainer]`, `[TextureRect]`, `[MarginContainer]` 等
- 附加属性：`key:value` 形式，如 `m:12,12,12,12` (九宫格边距)
- Companion 图层：`__9L`/`__9R`/`__9T`/`__9B` 后缀用于自动检测九宫格
- TextLayerBehavior(MergeToTexture) 下，普通图层自动映射为 Label

### 注意

- `psd_parser.gd` 超过 800 行，考虑拆分为更小的模块
- 插件没有单独的测试文件
- `psd-tools/` 是上游 Python 库，由 `.gitignore` 忽略
- 异步导入使用 `await get_tree().process_frame` 保持编辑器响应
