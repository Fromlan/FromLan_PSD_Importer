class_name LayerTreeBuilder
extends RefCounted

## PSD 图层树构建器。
## 利用 LayerRecord 的 SectionDivider 信息将扁平图层列表转换为树形 LayerNode 结构。

#region LayerNode

class LayerNode extends RefCounted:
	## 图层节点在场景树中的角色
	enum NodeType {
		ROOT,   ## 虚拟根节点（不渲染）
		GROUP,  ## PSD 文件夹/组 → 生成 Container/Control
		LAYER,  ## 叶子图层 → 生成 TextureRect/Label/Button 等
	}

	var node_type: NodeType = NodeType.LAYER
	var name: String = ""                   ## 净化后的 Godot 节点名
	var image_data: ImageData = null        ## 仅 LAYER 节点有效
	var layer_record = null                 ## LayerRecord 引用（GROUP 和 LAYER）
	var section_divider: int = 0            ## SectionDividerType 值
	var children: Array[LayerNode] = []     ## 子节点列表
	var bounds: Rect2i = Rect2i()           ## 在 PSD 坐标系中的边界框
	var target_node_type: String = "TextureRect"  ## 目标 Godot 节点类型
	var extra_properties: Dictionary = {}   ## 额外属性（9-slice margins 等）
	var ext_resource_id: String = ""        ## ext_resource ID（场景生成时填充）
	var is_hidden: bool = false             ## 图层是否隐藏
	var opacity: int = 255                  ## 图层不透明度（0-255）

#endregion

#region Tree Building

## 从 LayerRecord 和 ImageData 数组构建图层树。
## [param layer_records] 从 PSD 解析出的所有图层记录。
## [param image_data_list] 对应每个图层的 ImageData（同索引对应）。
## 返回虚拟根 LayerNode。
static func build_tree(layer_records: Array, image_data_list: Array[ImageData]) -> LayerNode:
	var root := LayerNode.new()
	root.node_type = LayerNode.NodeType.ROOT
	root.name = "ROOT"

	# 第 1 步：为每条记录创建 LayerNode
	# PSD 图层从底部到顶部存储，SectionDivider 的 BoundingSection 关闭最近打开的组
	var layer_nodes: Array[LayerNode] = []
	var node_stack: Array[LayerNode] = [root]
	var record_count := layer_records.size()

	for i in range(record_count - 1, -1, -1):
		var record = layer_records[i]
		var node := LayerNode.new()
		node.layer_record = record
		node.section_divider = record.section_divider
		node.is_hidden = (record.flags & 0x2) != 0  # Flags.Hidden
		node.opacity = record.opacity

		match record.section_divider:
			1, 2: # OpenFolder, ClosedFolder
				node.node_type = LayerNode.NodeType.GROUP
				node.name = _safe_node_name(record.layer_name)
				# 计算 GROUP 的边界为已有子节点的并集
				_compute_group_bounds(node)
				node_stack[node_stack.size() - 1].children.append(node)
				node_stack.append(node)
			0: # Any (regular layer)
				node.node_type = LayerNode.NodeType.LAYER
				var img_data := image_data_list[i]
				node.image_data = img_data
				node.name = _safe_node_name(img_data.name)
				node.bounds = Rect2i(img_data.position, img_data.image.get_size())
				node_stack[node_stack.size() - 1].children.append(node)
				layer_nodes.append(node)
			3: # BoundingSection
				if node_stack.size() > 1:
					var closed_group := node_stack.pop_back()
					_compute_group_bounds(closed_group)
			_:
				# 未识别的 section_divider，当作普通图层处理
				node.node_type = LayerNode.NodeType.LAYER
				var img_data := image_data_list[i]
				node.image_data = img_data
				node.name = _safe_node_name(img_data.name)
				node.bounds = Rect2i(img_data.position, img_data.image.get_size())
				node_stack[node_stack.size() - 1].children.append(node)
				layer_nodes.append(node)

	# 收尾：补算所有未闭合组的边界
	while node_stack.size() > 1:
		var open_group := node_stack.pop_back()
		_compute_group_bounds(open_group)

	return root

## 计算 GROUP 节点的边界框为其所有子节点边界的并集。
static func _compute_group_bounds(group: LayerNode) -> void:
	if group.children.is_empty():
		group.bounds = Rect2i()
		return
	var min_x := 0x7FFFFFFF
	var min_y := 0x7FFFFFFF
	var max_x := -0x7FFFFFFF
	var max_y := -0x7FFFFFFF
	for child: LayerNode in group.children:
		var cb := child.bounds
		if cb.size.x <= 0 and cb.size.y <= 0:
			continue
		min_x = mini(min_x, cb.position.x)
		min_y = mini(min_y, cb.position.y)
		max_x = maxi(max_x, cb.position.x + cb.size.x)
		max_y = maxi(max_y, cb.position.y + cb.size.y)
	if min_x == 0x7FFFFFFF:
		group.bounds = Rect2i()
	else:
		group.bounds = Rect2i(min_x, min_y, max_x - min_x, max_y - min_y)

#endregion

#region Helpers

## 将图层名净化为安全的 Godot 节点名。
static func _safe_node_name(value: String) -> String:
	var result := value.strip_edges()
	if result == "":
		return "unnamed"
	var invalid_chars := ["<", ">", ":", "\"", "/", "\\", "|", "?", "*", "."]
	for ch: String in invalid_chars:
		result = result.replace(ch, "_")
	return result

#endregion
