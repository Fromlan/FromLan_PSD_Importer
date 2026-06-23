class_name BigEndieanReader
extends RefCounted

## PSD 大端字节序读取器。
## 用于从 FileAccess 中以大端序读取各种数据类型，并包含边界安全的跳过逻辑。

var _file: FileAccess

## 初始化大端读取器并保存底层文件句柄。
func _init(file: FileAccess) -> void:
	_file = file

## 读取 ASCII 头并验证它是否匹配期望值。
func get_and_match_header(header: String, source: String) -> bool:
	var buffer := get_ascii(header.length())
	if buffer == header:
		return true
	push_error("Header Mismatch at %s: %s != %s" % [source, buffer, header])
	return false

## 读取指定长度的 ASCII 字符串。
func get_ascii(length: int) -> String:
	return _file.get_buffer(length).get_string_from_ascii()

## 读取指定长度的原始字节。
func get_buffer(length: int) -> PackedByteArray:
	return _file.get_buffer(length)

## 读取文件剩余全部字节。
func get_rest() -> PackedByteArray:
	return _file.get_buffer(_file.get_length() - _file.get_position())

## 读取 8 位无符号整数。
func get_u8() -> int:
	return _file.get_8()

## 读取 32 位大端无符号整数。
func get_u32() -> int:
	return _get_reversed(4).decode_u32(0)

## 读取 16 位大端无符号整数。
func get_u16() -> int:
	return _get_reversed(2).decode_u16(0)

## 读取 32 位大端有符号整数。
func get_s32() -> int:
	return _get_reversed(4).decode_s32(0)

## 读取 16 位大端有符号整数。
func get_s16() -> int:
	return _get_reversed(2).decode_s16(0)

## 读取 64 位大端 IEEE 754 浮点数（double）。
func get_f64() -> float:
	return _get_reversed(8).decode_double(0)

## 读取字节并反转以匹配 Godot 小端解码顺序。
func _get_reversed(size: int) -> PackedByteArray:
	var buffer := _file.get_buffer(size)
	buffer.reverse()
	return buffer

## 跳过指定字节数。
func skip(size: int) -> void:
	_file.seek(_file.get_position() + size)

## 移动读取位置到指定绝对偏移。
func seek(pos: int) -> void:
	_file.seek(pos)

## 返回当前读取位置。
func get_position() -> int:
	return _file.get_position()

## 返回底层文件总长度。
func get_file_length() -> int:
	return _file.get_length()
