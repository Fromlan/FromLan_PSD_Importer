class_name ImageData
extends RefCounted

## PSD 图层图像数据记录，保存解码后的 Image 和图层元信息。
var image: Image
var name: String
var group_path: String
var position: Vector2i
var source_size: Vector2i

## 初始化一个 PSD 图层图像记录。
func _init(p_image: Image, p_name: String, p_group_path: String = "", p_position: Vector2i = Vector2i.ZERO, p_source_size: Vector2i = Vector2i.ZERO) -> void:
	image = p_image
	name = p_name
	group_path = p_group_path
	position = p_position
	source_size = p_source_size
