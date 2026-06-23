class_name PSDParser
extends RefCounted

## PSD binary file parser engine.
## Contains all PSD format parsing logic: file header, layer records, channel decoding, GBK encoding, etc.

const BYTES_PER_PIXEL := 4
const TyShParserClass := preload("res://addons/FromLan_PSD_Importer/ty_sh_parser.gd")

#region Enums

enum ColorMode {
	Bitmap = 0,
	Grayscale = 1,
	Indexed = 2,
	RGB = 3,
	CMYK = 4,
	Multichannel = 5,
	Duotone = 8,
	Lab = 9,
}

enum CompressionMethod {
	Raw = 0,
	RLE = 1,
	Zip = 2,
	ZipWithPrediction = 3,
}

#endregion

#region Main Entry Point

## Optional progress callback. Called once per layer when set; used for UI progress updates.
## Note: this callback is invoked in a synchronous context and cannot yield; mainly for print/status logging.
static var progress_callback: Callable = Callable()

## Cached layer records from the most recent non-merged import.
static var _last_layer_records: Array = []
## Cached layer textures from the most recent non-merged import (1:1 with layer_records, including group marker layers).
static var _last_layer_texture: Array[ImageData] = []

## Get the layer records from the most recent read_psd_file call.
static func get_last_layer_records() -> Array:
	return _last_layer_records

## Get the layer textures from the most recent read_psd_file call (1:1 with layer_records).
static func get_last_layer_texture() -> Array[ImageData]:
	return _last_layer_texture

## Read a PSD file and return merged or per-layer image data (async version, supports per-layer callbacks).
## Yields to the main thread after each layer via yield_target to keep the editor responsive.
## [param yield_target] Node reference for await get_tree().process_frame.
## [param layer_decoded_callback] Optional callback invoked after each layer is decoded, receiving an ImageData parameter.
##   Useful for saving the current layer's PNG immediately in the callback. Note: ImageData.group_path is not set at this stage.
static func read_psd_file_async(path: String, merged: bool, layer_name_encoding: int, trim_layer: bool, mask_handling: int = 0, yield_target: Node = null, layer_decoded_callback: Callable = Callable()) -> Array[ImageData]:
	_last_layer_records.clear()
	_last_layer_texture.clear()
	var psd_file := FileAccess.open(path, FileAccess.READ)
	print("Start Importing PSD Document (%s)" % path)
	if !psd_file:
		push_error("Access Error: %s" % FileAccess.get_open_error())
		return []
	var reader := BigEndieanReader.new(psd_file)
	if !reader.get_and_match_header("8BPS", "File Start"):
		return []
	var version := reader.get_u16()
	if version != 1:
		push_error("PSD Format Error: %s != 1" % version)
		return []
	var reserved_bytes := psd_file.get_buffer(6)
	if reserved_bytes != PackedByteArray([0, 0, 0, 0, 0, 0]):
		push_error("Reserved Segment Error: %s != [0,0,0,0,0,0]" % reserved_bytes)
		return []
	var channels := reader.get_u16()
	if channels < 1 || channels > 56:
		push_error("Channel Count Error: %s != 1 ~ 56" % channels)
		return []
	var document_height := reader.get_u32()
	if document_height < 1 || document_height > 16384:
		push_error("Image Height Error: %s != 1 ~ 16384" % document_height)
		return []
	var document_width := reader.get_u32()
	if document_width < 1 || document_width > 16384:
		push_error("Image Width Error: %s != 1 ~ 16384" % document_width)
		return []
	var channel_bit_depth := reader.get_u16()
	if ![1, 8, 16, 32].has(channel_bit_depth):
		push_error("Channel Depth Error: %s != 1 | 8 | 16 | 32" % channel_bit_depth)
		return []
	var color_mode_value := reader.get_u16()
	if color_mode_value > 9:
		push_error("Color Mode Error: %s > 9" % color_mode_value)
		return []
	var color_mode: ColorMode = color_mode_value
	var color_data_length := reader.get_u32()
	match color_mode:
		ColorMode.Indexed:
			if color_data_length != 768:
				push_error("Index Color Mode Data Error: %s != 768" % [color_data_length])
				return []
			reader.skip(768)
		ColorMode.Duotone:
			reader.skip(color_data_length)
		_:
			if color_data_length != 0:
				push_error("Color Mode Data Error: %s != 0 for %s" % [color_data_length, ColorMode.keys()[color_mode]])
				return []

	var image_resource_length := reader.get_u32()
	reader.skip(image_resource_length)
	var layer_and_mask_length := reader.get_u32()
	if !merged:
		if layer_and_mask_length == 0:
			return []
		var layer_info_length := reader.get_u32()
		const IMPORT_TIMEOUT_MS := 120_000
		var import_start_ms := Time.get_ticks_msec()
		var layer_count := reader.get_s16()
		layer_count = absi(layer_count)
		print_rich("\n[color=cyan]========== PSD Import Diagnostic ==========[/color]")
		print_rich("  Document: %dx%dpx, %d channels, %d-bit" % [document_width, document_height, channels, channel_bit_depth])
		print_rich("  Layers: %d" % layer_count)
		print_rich("  Trim: %s" % trim_layer)
		print_rich("============================================\n[/color]")
		if layer_count > 50:
			print_rich("[color=yellow]Warning: %d layers. Import will yield after each layer to keep editor responsive.[/color]" % layer_count)
		var max_layers := 4096
		if layer_count > max_layers:
			push_error("PSD declares %d layers (max allowed: %d)." % [layer_count, max_layers])
			return []
		var layer_records: Array[LayerRecord] = []
		for layer_index: int in range(layer_count):
			if layer_index % 32 == 0 and Time.get_ticks_msec() - import_start_ms > IMPORT_TIMEOUT_MS:
				push_error("PSD import timed out after %.1f seconds" % [IMPORT_TIMEOUT_MS / 1000.0])
				return []
			var record := LayerRecord.new()
			var result := record.parse_data(reader, layer_index, layer_name_encoding)
			if result != OK:
				return []
			layer_records.append(record)
		_last_layer_records = layer_records.duplicate()
		var layer_texture: Array[ImageData] = []
		var total_layers := layer_records.size()
		var imported_count := 0
		for layer_record in layer_records:
			imported_count += 1
			if imported_count % 8 == 0 and Time.get_ticks_msec() - import_start_ms > IMPORT_TIMEOUT_MS:
				push_error("PSD import timed out")
				return []
			# Yield to main thread after each layer to keep editor responsive
			if yield_target != null:
				await yield_target.get_tree().process_frame
			var layer_width := layer_record.right - layer_record.left
			var layer_height := layer_record.bottom - layer_record.top
			var layer_pixels := layer_width * layer_height
			var print_threshold := maxi(1, total_layers / 10)
			var should_print := imported_count <= 5 or imported_count % print_threshold == 0 or imported_count == total_layers
			if should_print:
				print_rich("[color=dim_gray][%3d/%3d][/color] Importing Layer '%s'... (%dx%d, %.1fM px)" % [imported_count, total_layers, layer_record.layer_name, layer_width, layer_height, layer_pixels / 1048576.0])
			var layer_position := Vector2i(layer_record.left, layer_record.top)
			var image := _read_layer_image(layer_width, layer_height, reader, layer_record.channel_info, mask_handling, layer_record.opacity)
			if !image:
				print_rich("[color=yellow]  Layer '%s': channel decode failed, using transparent placeholder[/color]" % layer_record.layer_name)
				image = Image.create_empty(maxi(1, layer_width), maxi(1, layer_height), false, Image.FORMAT_RGBA8)
			if layer_record.has_effects and (layer_width <= 1 or layer_height <= 1):
				print_rich("[color=yellow]  Layer#%s '%s': has effects/patterns but zero-size bounds, using placeholder[/color]" % [imported_count, layer_record.layer_name])
				var safe_w := mini(document_width, 4096)
				var safe_h := mini(document_height, 4096)
				image = Image.create_empty(safe_w, safe_h, false, Image.FORMAT_RGBA8)
				layer_position = Vector2i.ZERO
			if trim_layer:
				var is_full_frame := layer_position == Vector2i.ZERO and layer_width == document_width and layer_height == document_height
				var used_rect := image.get_used_rect() if not is_full_frame else Rect2i(Vector2i.ZERO, image.get_size())
				var used_pos := Vector2i(int(used_rect.position.x), int(used_rect.position.y))
				var used_size := Vector2i(int(used_rect.size.x), int(used_rect.size.y))
				if used_size.x > 0 and used_size.y > 0 and (used_pos != Vector2i.ZERO or used_size != image.get_size()):
					var cropped := Image.create_empty(used_size.x, used_size.y, false, Image.FORMAT_RGBA8)
					cropped.blit_rect(image, Rect2i(used_pos, used_size), Vector2i.ZERO)
					image = cropped
					layer_position += used_pos
			else:
				var canvas_w: int
				var canvas_h: int
				if document_width > 4096 or document_height > 4096:
					canvas_w = layer_position.x + image.get_width()
					canvas_h = layer_position.y + image.get_height()
				else:
					canvas_w = document_width
					canvas_h = document_height
				var channel_image := Image.create_empty(canvas_w, canvas_h, false, Image.FORMAT_RGBA8)
				channel_image.blit_rect(image, Rect2i(0, 0, image.get_width(), image.get_height()), layer_position)
				image = channel_image
				layer_position = Vector2i.ZERO
			layer_texture.append(ImageData.new(image, layer_record.layer_name, "", layer_position, Vector2i(document_width, document_height)))
			if progress_callback.is_valid():
				progress_callback.call(imported_count, total_layers)
			# Per-layer callback (for saving PNG immediately after decode in import_full_async)
			if layer_decoded_callback.is_valid():
				await layer_decoded_callback.call(layer_texture[imported_count - 1])
		_last_layer_texture = layer_texture.duplicate()
		var group_stack: Array[String] = []
		var result_layers: Array[ImageData] = []
		for i in range(layer_records.size() - 1, -1, -1):
			var record := layer_records[i]
			match record.section_divider:
				LayerRecord.SectionDividerType.OpenFolder, LayerRecord.SectionDividerType.ClosedFolder:
					group_stack.push_back(record.layer_name)
				LayerRecord.SectionDividerType.BoundingSection:
					if group_stack.size() > 0:
						group_stack.pop_back()
				_:
					var img_data := layer_texture[i]
					result_layers.append(ImageData.new(img_data.image, img_data.name, "/".join(group_stack), img_data.position, img_data.source_size))
		result_layers.reverse()
		return result_layers
	else:
		# Merged mode
		reader.skip(layer_and_mask_length)
		var compression_method_value := reader.get_u16()
		if compression_method_value > 3:
			push_error("Incorrect compression mode: %s" % compression_method_value)
			return []
		var compression_method: CompressionMethod = compression_method_value
		if compression_method == CompressionMethod.Zip || compression_method == CompressionMethod.ZipWithPrediction:
			push_error("Unsupported compression mode: %s" % CompressionMethod.keys()[compression_method])
			return []
		var image_data_bytes := reader.get_rest()
		var created_image: Image
		if compression_method == CompressionMethod.Raw:
			var pixel_count := document_width * document_height
			var raw_data: PackedByteArray = []
			raw_data.resize(pixel_count * 4)
			for i in range(pixel_count):
				var idx := i
				raw_data[i * 4] = image_data_bytes[idx]
				raw_data[i * 4 + 1] = image_data_bytes[idx + pixel_count]
				raw_data[i * 4 + 2] = image_data_bytes[idx + pixel_count * 2]
				raw_data[i * 4 + 3] = image_data_bytes[idx + pixel_count * 3]
			created_image = Image.create_from_data(document_width, document_height, false, Image.FORMAT_RGBA8, raw_data)
		elif compression_method == CompressionMethod.RLE:
			var expected_merged_pixels := document_width * document_height * channels
			var decoded_data := _decode_rle_flat(image_data_bytes.slice(channels * 2 * document_height), expected_merged_pixels)
			if decoded_data.is_empty():
				return []
			var pixel_count := document_width * document_height
			var final_channels := 3 if channels == 3 else 4
			var rgba_data: PackedByteArray = []
			rgba_data.resize(pixel_count * final_channels)
			for i in range(pixel_count):
				for c in range(final_channels):
					rgba_data[i * final_channels + c] = decoded_data[i + pixel_count * c]
			if channels == 3:
				created_image = Image.create_from_data(document_width, document_height, false, Image.FORMAT_RGB8, rgba_data)
			elif channels == 4:
				created_image = Image.create_from_data(document_width, document_height, false, Image.FORMAT_RGBA8, rgba_data)
			else:
				push_error("Unsupported number of channels (%s != [3|4])" % channels)
		psd_file.close()
		if created_image:
			return [ImageData.new(created_image, "", "", Vector2i.ZERO, Vector2i(document_width, document_height))]
		return []

## Read a PSD file and return merged or per-layer image data (sync version).
static func read_psd_file(path: String, merged: bool, layer_name_encoding: int, trim_layer: bool, mask_handling: int = 0) -> Array[ImageData]:
	_last_layer_records.clear()
	_last_layer_texture.clear()
	var psd_file := FileAccess.open(path, FileAccess.READ)
	print("Start Importing PSD Document (%s)" % path)
	if !psd_file:
		push_error("Access Error: %s" % FileAccess.get_open_error())
		return []
	var reader := BigEndieanReader.new(psd_file)
	if !reader.get_and_match_header("8BPS", "File Start"):
		return []
	var version := reader.get_u16()
	if version != 1:
		push_error("PSD Format Error: %s != 1" % version)
		return []
	var reserved_bytes := psd_file.get_buffer(6)
	if reserved_bytes != PackedByteArray([0, 0, 0, 0, 0, 0]):
		push_error("Reserved Segment Error: %s != [0,0,0,0,0,0]" % reserved_bytes)
		return []
	var channels := reader.get_u16()
	if channels < 1 || channels > 56:
		push_error("Channel Count Error: %s != 1 ~ 56" % channels)
		return []
	var document_height := reader.get_u32()
	if document_height < 1 || document_height > 30000:
		push_error("Image Height Error: %s != 1 ~ 30000" % document_height)
		return []
	var document_width := reader.get_u32()
	if document_width < 1 || document_width > 30000:
		push_error("Image Width Error: %s != 1 ~ 30000" % document_width)
		return []
	var channel_bit_depth := reader.get_u16()
	if ![1, 8, 16, 32].has(channel_bit_depth):
		push_error("Channel Depth Error: %s != 1 | 8 | 16 | 32" % channel_bit_depth)
		return []
	var color_mode_value := reader.get_u16()
	if color_mode_value > 9:
		push_error("Color Mode Error: %s > 9" % color_mode_value)
		return []
	var color_mode: ColorMode = color_mode_value
	var color_data_length := reader.get_u32()
	match color_mode:
		ColorMode.Indexed:
			if color_data_length != 768:
				push_error("Index Color Mode Data Error: %s != 768" % [color_data_length])
				return []
			reader.skip(768)
		ColorMode.Duotone:
			reader.skip(color_data_length)
		_:
			if color_data_length != 0:
				push_error("Color Mode Data Error: %s != 0 for %s" % [color_data_length, ColorMode.keys()[color_mode]])
				return []

	var image_resource_length := reader.get_u32()
	reader.skip(image_resource_length)
	var layer_and_mask_length := reader.get_u32()
	if !merged:
		# Per-layer export mode
		if layer_and_mask_length == 0:
			return []
		# Layer info section length (aligned to multiple of 2)
		var layer_info_length := reader.get_u32()
		# Layer count. Negative means the first alpha channel contains merged result transparency.
		var layer_count := reader.get_s16()
		layer_count = absi(layer_count)
		var layer_records: Array[LayerRecord] = []
		# Parse each layer record
		for layer_index: int in range(layer_count):
			var record := LayerRecord.new()
			var result := record.parse_data(reader, layer_index, layer_name_encoding)
			if result != OK:
				return []
			layer_records.append(record)
		# Save parsed layer records for LayerTreeBuilder and subsequent steps
		_last_layer_records = layer_records.duplicate()
		var layer_texture: Array[ImageData] = []
		var total_layers := layer_records.size()
		var imported_count := 0
		for layer_record in layer_records:
			imported_count += 1
			print_rich("[color=dim_gray][%3d/%3d][/color] Importing Layer '%s'..." % [imported_count, total_layers, layer_record.layer_name])
			var layer_width := layer_record.right - layer_record.left
			var layer_height := layer_record.bottom - layer_record.top
			var layer_position := Vector2i(layer_record.left, layer_record.top)
			var image := _read_layer_image(layer_width, layer_height, reader, layer_record.channel_info, mask_handling)
			if !image:
				return []
			if layer_record.opacity != 255:
				_apply_layer_opacity(image, layer_record.opacity)
			if !trim_layer:
				var channel_image := Image.create_empty(document_width, document_height, false, Image.FORMAT_RGBA8)
				channel_image.blit_rect(image, Rect2i(0, 0, image.get_width(), image.get_height()), layer_position)
				image = channel_image
				layer_position = Vector2i.ZERO
			layer_texture.append(ImageData.new(image, layer_record.layer_name, "", layer_position, Vector2i(document_width, document_height)))
		# Save raw layer textures (1:1 with layer_records), for LayerTreeBuilder
		_last_layer_texture = layer_texture.duplicate()
		var group_stack: Array[String] = []
		var result_layers: Array[ImageData] = []
		for i in range(layer_records.size() - 1, -1, -1):
			var record := layer_records[i]
			match record.section_divider:
				LayerRecord.SectionDividerType.OpenFolder, LayerRecord.SectionDividerType.ClosedFolder:
					group_stack.push_back(record.layer_name)
				LayerRecord.SectionDividerType.BoundingSection:
					if group_stack.size() > 0:
						group_stack.pop_back()
				_:
					var img_data := layer_texture[i]
					result_layers.append(ImageData.new(img_data.image, img_data.name, "/".join(group_stack), img_data.position, img_data.source_size))
		result_layers.reverse()
		return result_layers
	else:
		# Merged mode: parse the composite image data at the end of the file
		reader.skip(layer_and_mask_length)
		var compression_method_value := reader.get_u16()
		if compression_method_value > 3:
			push_error("Incorrect compression mode: %s" % compression_method_value)
			return []
		var compression_method: CompressionMethod = compression_method_value
		if compression_method == CompressionMethod.Zip || compression_method == CompressionMethod.ZipWithPrediction:
			push_error("Unsupported compression mode: %s" % CompressionMethod.keys()[compression_method])
			return []
		var image_data_bytes := reader.get_rest()
		var created_image: Image
		if compression_method == CompressionMethod.Raw:
			var image_data: PackedByteArray = []
			var input_pos := 0
			while input_pos < document_width * document_height:
				for i in range(4):
					var data_byte := image_data_bytes.decode_u8(input_pos + document_width * document_height * i)
					image_data.append(data_byte)
				input_pos += 1
			created_image = Image.create_from_data(document_width, document_height, false, Image.FORMAT_RGBA8, image_data)
		elif compression_method == CompressionMethod.RLE:
			var decoded_data := _decode_rle_flat(image_data_bytes.slice(channels * 2 * document_height))
			if decoded_data.is_empty():
				return []
			var image_data: PackedByteArray = []
			var input_pos := 0
			while input_pos < document_width * document_height:
				for i in range(channels):
					image_data.append(decoded_data[input_pos + document_width * document_height * i])
				input_pos += 1
			if channels == 3:
				created_image = Image.create_from_data(document_width, document_height, false, Image.FORMAT_RGB8, image_data)
			elif channels == 4:
				created_image = Image.create_from_data(document_width, document_height, false, Image.FORMAT_RGBA8, image_data)
			else:
				push_error("Unsupported number of channels (%s != [3|4])" % channels)
		psd_file.close()
		if created_image:
			return [ImageData.new(created_image, "", "", Vector2i.ZERO, Vector2i(document_width, document_height))]
		return []

#endregion

#region Layer Image Decoding

## Read and decode a single PSD layer's channel image.
static func _read_layer_image(width: int, height: int, reader: BigEndieanReader, channel_info: Array, mask_handling: int = 0, opacity: int = 255) -> Image:
	if width <= 0 || height <= 0:
		for channel in channel_info:
			reader.skip(channel.data_length)
		return Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	var result: Dictionary = {} # LayerRecord.ChannelKind -> ChannelData
	for channel in channel_info:
		var start := reader.get_position()
		var compression: CompressionMethod = reader.get_u16()
		var data: PackedByteArray = []
		match compression:
			CompressionMethod.Raw:
				data = reader.get_buffer(channel.data_length)
			CompressionMethod.RLE:
				# Read scanline byte count table then the actual RLE body
				var rle_buffer_size := 0
				if channel.data_length > 0:
					var scanlines_count: int
					match channel.kind:
						LayerRecord.ChannelKind.UserSuppliedLayerMask, LayerRecord.ChannelKind.RealUserSuppliedLayerMask:
							# mask_handling: 0=Error, 1=Skip, 2=Apply (not yet implemented)
							if mask_handling == 0:
								push_error("Channel UserSuppliedLayerMask not supported (set layer_mask_handling=Skip to ignore)")
								return null
							# Skip/Apply mode: continue processing (Apply currently same as Skip)
						_:
							scanlines_count = height
					# Sum scanline byte counts from the header table
					for _idx in range(scanlines_count):
						rle_buffer_size += reader.get_u16()
				data = reader.get_buffer(rle_buffer_size)
			CompressionMethod.Zip:
				push_error("Zip image format not supported")
				return null
			CompressionMethod.ZipWithPrediction:
				push_error("Zip(with prediction) image format not supported")
				return null
		var remainder: int = channel.data_length - reader.get_position() + start
		reader.skip(remainder)
		result.get_or_add(channel.kind, ChannelData.new(compression, data))
	if !result.has(LayerRecord.ChannelKind.Red):
		push_error("Red Channel not found for layer")
		return null
	if !result.has(LayerRecord.ChannelKind.Green):
		push_error("Green Channel not found for layer")
		return null
	if !result.has(LayerRecord.ChannelKind.Blue):
		push_error("Blue Channel not found for layer")
		return null
	if !result.has(LayerRecord.ChannelKind.TransparencyMask):
		push_error("Alpha Channel not found for layer")
		return null
	var r_channel := result[LayerRecord.ChannelKind.Red] as ChannelData
	var g_channel := result[LayerRecord.ChannelKind.Green] as ChannelData
	var b_channel := result[LayerRecord.ChannelKind.Blue] as ChannelData
	var a_channel := result[LayerRecord.ChannelKind.TransparencyMask] as ChannelData
	var array := ByRefByteArray.new()
	var pixel_count := width * height
	array.inner.resize(pixel_count * BYTES_PER_PIXEL)
	if !_decode_channel(r_channel, 0, array): return null
	if !_decode_channel(g_channel, 1, array): return null
	if !_decode_channel(b_channel, 2, array): return null
	if !_decode_channel(a_channel, 3, array): return null
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, array.inner)

## Decode a single PSD channel into the RGBA output buffer at the specified offset.
static func _decode_channel(data: ChannelData, offset: int, buffer: ByRefByteArray) -> bool:
	match data.compression:
		CompressionMethod.Raw:
			return _decode_raw(data.data, offset, buffer)
		CompressionMethod.RLE:
			return _decode_rle(data.data, offset, buffer)
		_:
			push_error("Unsupported Compression Format: %s" % CompressionMethod.keys()[data.compression])
			return false

## Decode raw PSD channel data.
static func _decode_raw(input: PackedByteArray, channel_offset: int, output: ByRefByteArray) -> bool:
	var output_pos := channel_offset
	for value in input:
		if output_pos >= output.inner.size():
			push_error("output slice is too small")
			return false
		output.inner[output_pos] = value
		output_pos += BYTES_PER_PIXEL
	return true

## Decode PackBits RLE compressed data into a flat byte sequence.
## Returns the decoded PackedByteArray, or an empty array on error.
static func _decode_rle_flat(input: PackedByteArray, expected_total: int = -1) -> PackedByteArray:
	var output: PackedByteArray = []
	var input_pos := 0
	while input_pos < input.size():
		var header := input[input_pos]
		if header > 127:
			header -= 256
		input_pos += 1
		if header == -128:
			continue
		elif header >= 0:
			for _i in range(header + 1):
				if input_pos >= input.size():
					push_error("input terminated while decoding uncompressed segment in RLE slice")
					return []
				output.append(input[input_pos])
				input_pos += 1
		else:
			if input_pos >= input.size():
				push_error("input terminated while decoding repeat segment in RLE slice")
				return []
			var repeat := input[input_pos]
			input_pos += 1
			for _i in range(1 + (-header)):
				output.append(repeat)
	return output

## Decode RLE data with per-scanline byte counts (PSD big-endian format, manual assembly).
## Decode PackBits RLE compressed PSD channel data.
static func _decode_rle(input: PackedByteArray, channel_offset: int, output: ByRefByteArray) -> bool:
	var flat := _decode_rle_flat(input)
	if flat.is_empty():
		return false
	var output_pos := channel_offset
	for value in flat:
		if output_pos >= output.inner.size():
			push_error("output slice is too small (%s >= %s)" % [output_pos, output.inner.size()])
			return false
		output.inner[output_pos] = value
		output_pos += BYTES_PER_PIXEL
	return true

## Apply layer opacity (0-255) to the image's alpha channel.
## Uses raw buffer operations to avoid get_pixel/set_pixel C++ boundary overhead.
## Only call when opacity < 255; caller should skip opacity == 255 for performance.
static func _apply_layer_opacity(image: Image, opacity: int) -> void:
	var scale := float(opacity) / 255.0
	var data := image.get_data()
	# RGBA8 format: every 4 bytes is a pixel, 4th byte (index 3,7,11...) is alpha
	for i in range(3, data.size(), 4):
		data.set(i, int(float(data[i]) * scale))
	image.set_data(image.get_width(), image.get_height(), false, image.get_format(), data)

#endregion

#region Inner Classes

class ByRefByteArray extends RefCounted:
	var inner: PackedByteArray = []

class LayerRecord extends RefCounted:
	enum ChannelKind {
		Red = 0,
		Green = 1,
		Blue = 2,
		TransparencyMask = -1,
		UserSuppliedLayerMask = -2,
		RealUserSuppliedLayerMask = -3,
	}

	enum Flags {
		TransparencyProtected = 1 << 0,
		Hidden = 1 << 1,
		Obsolete = 1 << 2,
		Bit4HasUsefulInfo = 1 << 3,
		PixelDataIrrelevantToAppearance = 1 << 4,
	}

	enum SectionDividerType {
		Any = 0,
		OpenFolder = 1,
		ClosedFolder = 2,
		BoundingSection = 3,
	}

	var top: int = 0
	var left: int = 0
	var bottom: int = 0
	var right: int = 0
	var channel_count: int = 0
	var channel_info: Array[ChannelInfo] = []
	var blend_mode: String = ""
	var opacity: int = 255
	var clipping_is_base: bool = true
	var flags: Flags = 0
	var layer_name: String = ""
	var section_divider: SectionDividerType = SectionDividerType.Any
	var ty_sh_data = null ## TyShData, set when the layer has a TySh block
	var has_effects: bool = false ## Set to true when the layer has effects or pattern data (soLE/PAT1/PAT2/PAT3/PATT)

	## Return a debug description of this layer record.
	func _to_string() -> String:
		return "<%s: %s, %s, %s, %s, %s, %s, %s>" % [layer_name, [top, left, bottom, right], channel_count, channel_info, blend_mode, opacity, clipping_is_base, flags]

	## Round an integer up to a multiple for PSD segment alignment.
	static func _round_up_to_multiple(num_to_round: int, to_multiple_of: int) -> int:
		return (num_to_round + (to_multiple_of - 1)) & ~(to_multiple_of - 1)

	## Check if a byte array is valid UTF-8.
	## Used to avoid Godot engine printing many Unicode parsing errors from get_string_from_utf8().
	static func _is_valid_utf8(bytes: PackedByteArray) -> bool:
		var i := 0
		while i < bytes.size():
			var b := bytes[i]
			if b < 0x80:
				# ASCII single-byte character (0xxxxxxx)
				i += 1
			elif b < 0xC0:
				# Invalid continuation byte (10xxxxxx can't be a start byte)
				return false
			elif b < 0xE0:
				# Two-byte sequence (110xxxxx 10xxxxxx)
				if i + 1 >= bytes.size(): return false
				if (bytes[i + 1] & 0xC0) != 0x80: return false
				i += 2
			elif b < 0xF0:
				# Three-byte sequence (1110xxxx 10xxxxxx 10xxxxxx)
				if i + 2 >= bytes.size(): return false
				if (bytes[i + 1] & 0xC0) != 0x80: return false
				if (bytes[i + 2] & 0xC0) != 0x80: return false
				i += 3
			elif b < 0xF8:
				# Four-byte sequence (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
				if i + 3 >= bytes.size(): return false
				if (bytes[i + 1] & 0xC0) != 0x80: return false
				if (bytes[i + 2] & 0xC0) != 0x80: return false
				if (bytes[i + 3] & 0xC0) != 0x80: return false
				i += 4
			else:
				# Invalid start byte (>= 0xF8)
				return false
		return true

	## Parse a single layer record from the PSD layer info section.
	func parse_data(file: BigEndieanReader, layer_index: int, layer_name_encoding: int) -> Error:
		top = file.get_s32()
		left = file.get_s32()
		bottom = file.get_s32()
		right = file.get_s32()

		channel_count = file.get_u16()
		for channel_index in range(channel_count):
			var channel_id := file.get_s16()
			if channel_id < -3 || channel_id > 2:
				push_error("ChannelKind Error in Layer#%s Channel#%s: %s < -3 || %s > 2" % [layer_index, channel_index, channel_id, channel_id])
				return ERR_FILE_CORRUPT
			var channel_kind: LayerRecord.ChannelKind = channel_id
			var channel_data_length := file.get_u32()
			channel_info.append(ChannelInfo.new(channel_kind, channel_data_length))
		if !file.get_and_match_header("8BIM", "Layer#%s (Blend Mode)" % layer_index):
			return ERR_FILE_CORRUPT
		var blend_mode_key := file.get_ascii(4)
		if blend_mode_key != "norm":
			print_rich("[color=light_gray]  Layer#%s: non-normal blend mode '%s' (raw pixels will be used as-is)[/color]" % [layer_index, blend_mode_key])
		# 0 == 0.0, 255 == 1.0
		opacity = file.get_u8()
		if opacity != 255:
			print_rich("[color=light_gray]  Layer#%s opacity: %s/255 (will be applied to alpha)[/color]" % [layer_index, opacity])
		var clipping_value := file.get_u8()
		clipping_is_base = clipping_value == 0
		if !clipping_is_base:
			print_rich("[color=light_gray]  Layer#%s: non-base clipping (value=%s), layers may not composite correctly[/color]" % [layer_index, clipping_value])
		flags = file.get_u8()
		file.get_u8() # One Byte Padding

		var extra_data_length := file.get_u32()
		var layer_mask_length := file.get_u32()
		if layer_mask_length != 0:
			print_rich("[color=yellow]  Layer#%s: has mask data (%s bytes), skipping[/color]" % [layer_index, layer_mask_length])
		file.skip(layer_mask_length)

		var layer_blending_range_length := file.get_u32()
		file.skip(layer_blending_range_length)
		var name_length := file.get_u8()
		var padded_length := _round_up_to_multiple(name_length + 1, 4)
		var name_bytes := file.get_buffer(name_length)
		var skipped_bytes := padded_length - name_length - 1
		file.skip(skipped_bytes)
		match layer_name_encoding:
			0: # LayerNameEncoding.Utf8
				# Validate UTF-8 first to avoid Godot get_string_from_utf8() printing many errors on GBK bytes
				if _is_valid_utf8(name_bytes):
					layer_name = name_bytes.get_string_from_utf8()
				else:
					# Auto-fallback to GBK decoding (common for Chinese layer names in PSD files)
					print_rich("[color=dim_gray]  Layer#%s: UTF-8 decode failed, falling back to GBK[/color]" % layer_index)
					layer_name = GBKEncoding.get_string_from_gbk(name_bytes)
			1: # LayerNameEncoding.GBK
				layer_name = GBKEncoding.get_string_from_gbk(name_bytes)
			_:
				push_error("Unsupported layer name encoding: %s" % layer_name_encoding)
				return ERR_CANT_RESOLVE
		var additional_info_length := extra_data_length - layer_mask_length - layer_blending_range_length - padded_length - 8
		# Safety check: prevent huge negative values or values exceeding remaining file space from corrupt PSDs
		var remaining_file := file.get_file_length() - file.get_position()
		if additional_info_length < 0 or additional_info_length > remaining_file:
			print_rich("[color=yellow]  Layer#%s: additional_info_length %s exceeds remaining file (%s), clamping[/color]" % [layer_index, additional_info_length, remaining_file])
			additional_info_length = maxi(0, mini(additional_info_length, remaining_file))
		var additional_info_start := file.get_position()
		var additional_info_end := additional_info_start + additional_info_length
		# Safety limit: prevent infinite loops from zero-length tag blocks or corrupt data
		var max_additional_blocks := 8192
		var additional_block_count := 0
		var had_valid_block := false
		while file.get_position() < additional_info_end and additional_block_count < max_additional_blocks:
			additional_block_count += 1
			if !file.get_and_match_header("8BIM", "Layer#%s (Additional Info)" % layer_index):
				# Non-8BIM start: if we already parsed valid blocks, it may be trailing garbage
				if had_valid_block:
					print_rich("[color=dim_gray]  Layer#%s: additional info ended (non-8BIM after valid blocks, position=%d)[/color]" % [layer_index, file.get_position()])
					break
				return ERR_FILE_CORRUPT
			var key := file.get_ascii(4)
			var data_length := file.get_u32()
			var data_start := file.get_position()
			# Validate data_length against remaining space
			var max_data_length := additional_info_end - data_start
			if data_length > max_data_length:
				print_rich("[color=yellow]  Layer#%s: block %s claims %s bytes but only %s remain, clamping[/color]" % [layer_index, key, data_length, max_data_length])
				data_length = maxi(0, max_data_length)
			match key:
				"lsct":
					var section_divider_type_value := file.get_u32()
					match section_divider_type_value:
						0: section_divider = SectionDividerType.Any
						1: section_divider = SectionDividerType.OpenFolder
						2: section_divider = SectionDividerType.ClosedFolder
						3: section_divider = SectionDividerType.BoundingSection
						_:
							push_error("Unsupported Section Divider Type in Layer#%s: %s" % [layer_index, section_divider_type_value])
							return ERR_FILE_CORRUPT
				"TySh":
					# Parse text engine data
					var parsed_ty_sh = TyShParserClass.parse_ty_sh(file, data_length)
					if parsed_ty_sh != null and parsed_ty_sh.is_valid:
						ty_sh_data = parsed_ty_sh
				"PATT":
					# Pattern reference empty marker block, no data
					has_effects = true
					print_rich("[color=dim_gray]  Layer#%s: pattern reference block (PATT)[/color]" % layer_index)
				"PAT1", "PAT2", "PAT3":
					has_effects = true
					print_rich("[color=dim_gray]  Layer#%s: embedded pattern data (%s, %s bytes)[/color]" % [layer_index, key, data_length])
				"soLE", "SOLE":
					has_effects = true
					print_rich("[color=dim_gray]  Layer#%s: object-based effects layer info (%s bytes), skipping[/color]" % [layer_index, data_length])
				"FMsk":
					has_effects = true
					print_rich("[color=dim_gray]  Layer#%s: filter mask (%s bytes), skipping[/color]" % [layer_index, data_length])
				"fltr":
					print_rich("[color=dim_gray]  Layer#%s: filter effects (%s bytes), skipping[/color]" % [layer_index, data_length])
				"shap":
					print_rich("[color=dim_gray]  Layer#%s: shape layer (%s bytes), skipping[/color]" % [layer_index, data_length])
				"vogk":
					print_rich("[color=dim_gray]  Layer#%s: vector origination (%s bytes), skipping[/color]" % [layer_index, data_length])
			# Safely skip tag block data: advance at least 4 bytes for zero-length blocks to prevent infinite loops
			var aligned := _round_up_to_multiple(data_length, 2)
			if aligned <= 0:
				aligned = 4
			file.seek(data_start + aligned)
			had_valid_block = true
		file.seek(additional_info_end)
		return OK

class ChannelInfo extends RefCounted:
	var kind: LayerRecord.ChannelKind
	var data_length: int

	## Initialize layer channel metadata.
	func _init(p_kind: LayerRecord.ChannelKind, p_data_length: int) -> void:
		kind = p_kind
		data_length = p_data_length

class ChannelData extends RefCounted:
	var compression: CompressionMethod
	var data: PackedByteArray = []

	## Return a debug description of this channel data.
	func _to_string() -> String:
		return "%s[%s]" % [CompressionMethod.keys()[compression], data.size()]

	## Initialize read channel compressed data.
	func _init(p_compression: CompressionMethod, p_data: PackedByteArray) -> void:
		compression = p_compression
		data = p_data

#endregion
