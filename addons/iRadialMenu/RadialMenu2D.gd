# Script based on the work from "Advanced Radial Menu" by "ortyrx"
# https://github.com/diklor/advanced_radial_menu
# Edit author Dario "iRad" De Vita

@tool
@icon("icon_radial_2d.svg")
class_name RadialMenu2D extends Control

const SQRT_2: float = 1.4142

## If `true`, enables preview drawing in the editor. [br]
## When set, the radial menu will redraw itself in the editor to show a preview of its layout. [br]
## This is useful for visualizing changes to the menu's settings or items.
@export var preview_draw := true: set = _set_preview_draw

## If `true`, suppresses configuration warnings in the editor. [br]
## When set, the editor will not display warnings about invalid or incomplete menu items. [br]
## This is useful when dynamically adding items via script and you want to avoid warnings during development.
@export var suppress_warnings := false:
	set(val):
		suppress_warnings = val
		update_configuration_warnings()

## The list of menu items to display. Each item must be a [code]RadialMenuItem[/code]. [br]
## When set, the menu will update its layout to include the new items. [br]
## Each item in the array should define properties such as `option_name`, `description`, and `image`.
@export var items: Array[RadialMenuItem] = []:
	set(val):
		items = val
		update()

## The settings resource for configuring the appearance and behavior of the radial menu. [br]
## When set, the menu will apply the new settings and redraw itself. [br]
## The settings include properties such as dimensions, colors, and input actions.
@export var settings := RadialMenuSettings.new():
	set(val):
		settings = val
		if !settings.changed.is_connected(_on_settings_changed):
			settings.changed.connect(_on_settings_changed)

#region Functional variables
var selected_idx: int = -1
var items_validated: bool = false

var start_angle_offset_radiants: float
var center := Vector2.ZERO
var dim_inner_radius: float
var item_pos_radius: float # center position for items
var item_auto_dimension_max: int # center position for items
var items_radial_count: int
var sector_angle_full: float
var sector_angle_gap: float
var sector_angle_net: float
var sector_resolution: int

var _is_editor := true
var _is_focus_action_pressed := false
#endregion

#region Signals
signal selected(selected_idx: int)
signal selection_changed(selected_idx: int)
signal canceled
#endregion


#region Init
func _ready() -> void:
	_is_editor = Engine.is_editor_hint()
	if _is_editor:
		EditorInterface.get_inspector().property_edited.connect(_on_property_edited)
	gui_input.connect(_gui_input)
	await get_tree().process_frame
	queue_redraw()


func validate_items() -> bool:
	if items.is_empty():
		items_validated = false
		return false
	
	for item: RadialMenuItem in items:
		if not item:
			items_validated = false
			return false
		if not item.image:
			items_validated = false
			return false
	
	items_validated = true
	return items_validated
#endregion


#region Input
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if !event.is_pressed() or selected_idx == -1:
			return
		select()
	if event is InputEventMouseMotion:
		hover_at_local_position(event.position)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	
	# check for mouse
	if event is InputEventMouseMotion:
		hover_at_local_position(event.position)
	if event is InputEventMouseButton:
		if event.is_pressed() and settings.action_released:
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if selected_idx != -1:
				select()
			else:
				cancel()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			cancel()
	
	# check for actions
	if event is InputEventAction:
		if event.is_pressed() and settings.action_released:
			return
		
		var cancel_action_name: StringName = &"ui_cancel"
		var select_action_name: StringName = &"ui_select" if !settings.select_action_name else settings.select_action_name
		if event.is_action(cancel_action_name):
			cancel()
		
		if event.is_action(select_action_name):
			select()
	
	# check for controller
	if event is InputEventJoypadMotion and settings.controller_enabled:
		var controller_vector: Vector2 = Input.get_vector(
			settings.move_left_action_name if !settings.move_left_action_name.is_empty() else &"ui_left",
			settings.move_right_action_name if !settings.move_right_action_name.is_empty() else &"ui_right",
			settings.move_back_action_name if !settings.move_back_action_name.is_empty() else &"ui_down",
			settings.move_forward_action_name if !settings.move_forward_action_name.is_empty() else &"ui_up",
			settings.controller_deadzone
		)
		var pointer_vector: Vector2 = ui_input_vector_to_pointer_position(controller_vector)


## Hovers over the menu item at the given local position. [br]
## This function calculates the pointer's position relative to the menu center [br]
## and determines which menu item (if any) is being hovered over.
## @param _pos The local position to hover over.
func hover_at_local_position(_pos: Vector2) -> void:
	var pointer_pos: Vector2 = _pos - center
	hover_at_centered_pointer_position(pointer_pos)


func hover_at_centered_pointer_position(_pointer_pos: Vector2) -> void:
	if not is_visible_in_tree():
		return
	# pointer position is the position of the mouse or controller action compared to the center
	var prev_selected_idx := selected_idx
	selected_idx = get_selection_at_position(_pointer_pos)
	
	if selected_idx != prev_selected_idx:
		selection_changed.emit(selected_idx)
	
	queue_redraw()
#endregion


#region Update
## Updates the radial menu's layout and redraws it. [br]
## This function recalculates the menu's size, position, and item layout [br]
## based on the current settings and items.
func update() -> void:
	
	if !validate_items():
		return
	_calculate_size_values()
	queue_redraw()


func _calculate_size_values() -> void:
	# main circle
	center = (size / 2.0) + settings.dim_center_offset
	if settings.dim_autosize:
		settings.dim_outer_radius = _get_auto_circle_radius()
	dim_inner_radius = int(settings.dim_outer_radius * settings.dim_inner_radius_ratio)
	dim_inner_radius = clamp(dim_inner_radius, 4, settings.dim_outer_radius - (settings.reticle_outer_width + settings.reticle_inner_width) )
	start_angle_offset_radiants = deg_to_rad(settings.start_angle_offset)
	
	# sectors
	items_radial_count = items.size() if !settings.first_item_centered else items.size() - 1
	sector_angle_full = TAU/items_radial_count
	sector_resolution = max(int(settings.resolution / items_radial_count), 2)
	
	sector_angle_gap = settings.reticle_separator_width / dim_inner_radius
	sector_angle_net = sector_angle_full - sector_angle_gap
	
	# items
	var doughnut_width_full: float = settings.dim_outer_radius - dim_inner_radius
	var doughnut_width_net: float = doughnut_width_full - settings.reticle_inner_width - settings.reticle_outer_width
	item_pos_radius = dim_inner_radius + settings.reticle_inner_width + doughnut_width_net / 2.0
	
	item_auto_dimension_max = (doughnut_width_net/2.0) * SQRT_2 * settings.item_auto_size_factor


func _draw() -> void:
	if !items_validated:
		return
	if size == Vector2.ZERO:
		return
	_draw_background()
	_draw_reticle()
	_draw_highlight()
	_draw_icons()
	_draw_center_preview()


func _draw_background() -> void:
	if settings.first_item_centered or settings.bg_full_circle:
		draw_circle(center, settings.dim_outer_radius, settings.bg_circle_color, true, -1, settings.reticle_antialiased)
	elif settings.bg_texture:
		for i in items_radial_count:
			var angle_center_selected: float = i * sector_angle_full + sector_angle_full/2.0 + start_angle_offset_radiants
			var poly: PackedVector2Array = get_sector_points(
				center,
				angle_center_selected,
				sector_angle_net,
				dim_inner_radius,
				settings.dim_outer_radius,
				sector_resolution
			)
			var uv_poly: PackedVector2Array = uv_from_sector_poly(poly.size())
			draw_polygon(poly, [settings.bg_circle_color], uv_poly, settings.bg_texture)
	elif settings.reticle_separator_type == RadialMenuSettings.SeparatorType.SECTOR and !settings.reticle_separator_enabled:
		for i in items_radial_count:
			var angle_center_selected: float = i * sector_angle_full + sector_angle_full/2.0 + start_angle_offset_radiants
			var poly: PackedVector2Array = get_sector_points(
				center,
				angle_center_selected,
				sector_angle_net,
				dim_inner_radius,
				settings.dim_outer_radius,
				sector_resolution
			)
			draw_polygon(poly, [settings.bg_circle_color])
	else:
		# draw a doughnut
		var poly_right: PackedVector2Array = get_sector_points(
			center, 0, PI, dim_inner_radius, settings.dim_outer_radius, int(settings.resolution/2)
		)
		var poly_left: PackedVector2Array = get_sector_points(
			center, PI, PI, dim_inner_radius, settings.dim_outer_radius, int(settings.resolution/2)
		)
		draw_polygon(poly_right, [settings.bg_circle_color])
		draw_polygon(poly_left, [settings.bg_circle_color])


func _draw_reticle() -> void:
	var arc_start_angle: float = 0
	var arc_end_angle: float = TAU
	
	if settings.reticle_inner_enabled:
		draw_arc(
			center,
			dim_inner_radius + settings.reticle_inner_width/2.0,
			arc_start_angle,
			arc_end_angle,
			settings.resolution,
			settings.reticle_inner_color,
			settings.reticle_inner_width,
			settings.reticle_antialiased
		)
	
	if settings.reticle_outer_enabled:
		draw_arc(
			center,
			settings.dim_outer_radius - settings.reticle_outer_width/2.0,
			arc_start_angle,
			arc_end_angle,
			settings.resolution,
			settings.reticle_outer_color,
			settings.reticle_outer_width,
			settings.reticle_antialiased
		)
	if settings.reticle_separator_enabled:
		match settings.reticle_separator_type:
			RadialMenuSettings.SeparatorType.LINE:
				for i in items_radial_count:
					var point := Vector2.from_angle(i * sector_angle_full + start_angle_offset_radiants)
					draw_line(
						center + point * (dim_inner_radius + settings.reticle_inner_width/2.0),
						center + point * (settings.dim_outer_radius - settings.reticle_outer_width/2.0),
						settings.reticle_separator_color,
						settings.reticle_separator_width,
						settings.reticle_antialiased
					)
			RadialMenuSettings.SeparatorType.SECTOR:
				var res: int = int(settings.resolution/items_radial_count)
				for i in items_radial_count:
					var angle_center = i * sector_angle_full + start_angle_offset_radiants
					var poly: PackedVector2Array = get_sector_points(
						center,
						angle_center,
						sector_angle_gap,
						dim_inner_radius,
						settings.dim_outer_radius,
						res
					)
					draw_polygon(poly, [settings.reticle_separator_color])


func _draw_highlight() -> void:
	if selected_idx == -1:
		return
	if selected_idx == 0 and settings.first_item_centered:
		draw_circle(center, dim_inner_radius, settings.hover_color)
		return
	
	var idx: int = selected_idx if !settings.first_item_centered else selected_idx - 1
	var angle_center_selected: float = idx * sector_angle_full + sector_angle_full/2.0 + start_angle_offset_radiants
	var poly: PackedVector2Array = get_sector_points(
		center,
		angle_center_selected,
		sector_angle_net if settings.reticle_separator_type == RadialMenuSettings.SeparatorType.SECTOR else sector_angle_full,
		dim_inner_radius,
		settings.dim_outer_radius,
		sector_resolution
	)
	draw_polygon(poly, [settings.hover_color])


func _draw_icons() -> void:
	if settings.first_item_centered:
		var item: RadialMenuItem = items[0]
		var color: Color = settings.hover_child_modulate if selected_idx == 0 else settings.item_modulate
		draw_item_image_at_position(item, Vector2.ZERO, color)
	
	for i: int in items_radial_count:
		var idx: int = i
		if settings.first_item_centered:
			idx = i + 1
		
		var item: RadialMenuItem = items[idx]
		var item_angle_pos: float = i * sector_angle_full + sector_angle_full / 2.0
		item_angle_pos += start_angle_offset_radiants
		var image_pos: Vector2 = Vector2.from_angle(item_angle_pos) * item_pos_radius
		var color: Color = settings.hover_child_modulate if selected_idx == idx else settings.item_modulate
		
		draw_item_image_at_position(item, image_pos, color, item_angle_pos)


func _draw_center_preview() -> void:
	if selected_idx == -1 or settings.first_item_centered:
		return
	
	var item: RadialMenuItem = items[selected_idx]
	var _encircled_square_size: float = dim_inner_radius * SQRT_2
	#var _center_rect: Rect2 = Rect2(Vector2.ZERO, Vector2.ONE * _encircled_square_size)
	var _image_rect: Rect2 = Rect2(Vector2.ZERO ,item.image.get_size())
	var _center_rect: Rect2 = resized_rect_to_dimension(_image_rect, _encircled_square_size * settings.hover_size_factor)
	draw_item_image_at_position(item, Vector2.ZERO, settings.item_modulate, PI/2, _center_rect)
	
	# text option name and description
	var _top_left_pos: Vector2 = Vector2(-_encircled_square_size, -_encircled_square_size)/2.0 + center
	var _bot_left_pos: Vector2 = Vector2(-_encircled_square_size,  _encircled_square_size)/2.0 + center
	
	var _item_name_size: Vector2 = settings.text_font.get_string_size(
		item.option_name,
		HORIZONTAL_ALIGNMENT_CENTER,
		_encircled_square_size,
		settings.text_font_size_name,
	)
	draw_string(
		settings.text_font,
		_top_left_pos + Vector2.DOWN * _item_name_size.y,
		item.option_name,
		HORIZONTAL_ALIGNMENT_CENTER,
		_encircled_square_size,
		settings.text_font_size_name,
		settings.text_font_color_name,
	)
	
	# calculate text occupied space
	var _description_size: Vector2 = settings.text_font.get_multiline_string_size(
		item.description,
		HORIZONTAL_ALIGNMENT_CENTER,
		_encircled_square_size,
		settings.text_font_size_description, 3,
		TextServer.BREAK_WORD_BOUND,
		TextServer.JUSTIFICATION_WORD_BOUND
	)
	draw_multiline_string(
		settings.text_font,
		_bot_left_pos + Vector2.UP * _description_size.y,
		item.description,
		HORIZONTAL_ALIGNMENT_CENTER,
		_encircled_square_size,
		settings.text_font_size_description, 3,
		settings.text_font_color_description,
		TextServer.BREAK_WORD_BOUND,
		TextServer.JUSTIFICATION_WORD_BOUND
	)


func _process(_delta: float) -> void:
	if !_is_editor:
		return
	if preview_draw and self == EditorInterface.get_edited_scene_root():
		hover_at_local_position(get_local_mouse_position())
		update()
#endregion


#region Signals
func _on_property_edited(property: StringName) -> void:
	if property == &"items":
		update_configuration_warnings()


func _on_settings_changed() -> void:
	update()
#endregion


#region Getters/Setters
## Calculates and returns the auto circle radius based on the control's size. [br]
## This is used when the `dim_autosize` setting is enabled to dynamically [br]
## adjust the menu's outer radius.
## @return The calculated radius as an integer.
func _get_auto_circle_radius() -> int:
	if size.x < size.y:
		return int(size.x / 2.0)
	return int(size.y / 2.0)


## Sets the preview drawing state. [br]
## When enabled, the menu will continuously redraw itself in the editor [br]
## to reflect changes to its layout or settings.
## @param value If `true`, enables preview drawing.
func _set_preview_draw(value: bool) -> void:
	preview_draw = value
	set_process(value)
#endregion


#region Utilities
## Gets the index of the menu item at the given pointer position. [br]
## This function determines which menu item (if any) is located at the [br]
## specified pointer position relative to the menu center.
## @param _pointer_pos The pointer position relative to the menu center.
## @return The index of the menu item, or -1 if no item is selected.
func get_selection_at_position(_pointer_pos: Vector2) -> int:
	var angle: float = wrapf(_pointer_pos.angle() - start_angle_offset_radiants, 0.0, TAU)
	var _pointer_radius: float = _pointer_pos.length()
	var is_in_outer_circle: bool = _pointer_radius < settings.dim_outer_radius
	var is_in_inner_circle: bool = _pointer_radius < dim_inner_radius
	var is_in_doughnut: bool = is_in_outer_circle and not is_in_inner_circle
	
	if settings.first_item_centered and is_in_inner_circle:
		return 0
	
	if settings.keep_selection_outside or is_in_doughnut:
		var idx: int = floor((angle / TAU) * items_radial_count)
		if settings.first_item_centered:
			idx += 1
		return idx
	
	return -1


## Selects the currently hovered menu item and emits the [signal selected]. [br]
## This function triggers the callback associated with the selected item [br]
## and resets the selection state.
func select() -> void: # select currently hovered element
	if selected_idx == -1:
		cancel()
	else:
		selected.emit(selected_idx)
		var item: RadialMenuItem = items[selected_idx]
		print("Slot selected: %s" % item.option_name)
		if item.callback:
			item.callback.call_deferred()
	
	selected_idx = -1


## Cancels the current selection and emits the [signal canceled]. [br]
## This function clears the current selection and redraws the menu.
func cancel() -> void:
	selected_idx = -1
	canceled.emit()


## Converts a UI input vector to a pointer position. [br]
## This function maps a directional input (e.g., from a joystick) to a [br]
## position within the radial menu.
## @param _ui_input_vector The input vector.
## @return The pointer position as a [code]Vector2[/code].
func ui_input_vector_to_pointer_position(_ui_input_vector: Vector2) -> Vector2:
	return _ui_input_vector * settings.dim_outer_radius


func draw_item_image_at_position(
			_item: RadialMenuItem,
			_position: Vector2,
			_modulate: Color,
			_item_angle_position: float = 1.5708, # PI/2, 90 degrees
			_fixed_rect: Rect2 = Rect2()
		) -> void:
	
	var _texture: Texture2D = _item.image
	if not _texture: return
	
	var _rotation: float = 0.0
	var _rect: Rect2 = Rect2(Vector2.ZERO, _texture.get_size())
	
	if _fixed_rect == Rect2():
		var _rect_dim: float = settings.item_size
		if settings.item_auto_size and _fixed_rect == Rect2():
			_rect_dim = item_auto_dimension_max
		_rect = resized_rect_to_dimension(_rect, _rect_dim)
	else:
		_rect = _fixed_rect
	
	_rect.position = -_rect.size/2.0
	if settings.item_align:
		_rotation = wrapf(_item_angle_position + PI/2, -PI/2, PI/2)
	
	draw_set_transform(_position + center, _rotation)
	draw_texture_rect(_texture, _rect, false, _modulate)
	draw_set_transform(Vector2.ZERO)


## Gets the points of a sector (pie slice) in a circle. [br]
## This function calculates the vertices of a sector based on the given parameters. [br]
## It is useful for drawing pie slices or dividing a circle into segments. [br]
## The sector is defined by its center, inner and outer radii, and angular range.
## @param _center The center of the circle as a [code]Vector2[/code].
## @param _angle_center The angle at the center of the sector in radians.
## @param _angle_width The width of the sector in radians.
## @param _inner_radius The inner radius of the sector.
## @param _outer_radius The outer radius of the sector.
## @param _resolution The number of points used to approximate the sector's curve. Higher values result in smoother curves.
## @return A [code]PackedVector2Array[/code] containing the points of the sector. [br]
## The array includes points for both the inner and outer edges of the sector.
static func get_sector_points(
			_center: Vector2,
			_angle_center: float,
			_angle_width: float,
			_inner_radius: float,
			_outer_radius: float,
			_resolution: int,
		) -> PackedVector2Array:
	
	var half_width: float = _angle_width * 0.5
	var start_angle: float = _angle_center - half_width
	var end_angle: float = _angle_center + half_width
	
	var inner_p := PackedVector2Array()
	var outer_p := PackedVector2Array()
	
	for i in range(_resolution + 1):
		var t := float(i) / _resolution
		var angle := lerp(start_angle, end_angle, t)
		var dir := Vector2.from_angle(angle)
		inner_p.append(dir * _inner_radius + _center)
		outer_p.append(dir * _outer_radius + _center)
	
	outer_p.reverse()
	inner_p.append_array(outer_p)
	
	return inner_p


## Generates UV coordinates for a sector polygon. [br]
## This function creates UV mapping for a sector polygon, which can be used [br]
## to apply textures to the sector.
## @param _sector_poly_size The number of points in the sector polygon.
## @return A [code]PackedVector2Array[/code] containing the UV coordinates.
static func uv_from_sector_poly(_sector_poly_size: int) -> PackedVector2Array:
	var uv_poly := PackedVector2Array()
	var half_size: float = float(_sector_poly_size/2.0)
	var step: float = 1.0 / (half_size - 1.0)
	# inner points
	for i: int in half_size:
		var uv_p: Vector2 = Vector2(i * step, 0)
		uv_poly.append(uv_p)
	# outer points
	for i: int in half_size:
		var uv_p: Vector2 = Vector2((half_size -1 - i) * step, 1)
		uv_poly.append(uv_p)
	
	return uv_poly


## Resizes a rectangle to fit within a given dimension while maintaining its aspect ratio. [br]
## This function is useful for scaling images or UI elements to fit within a specific size.
## @param _original_rect The original rectangle to resize.
## @param _dimension The target dimension (width or height).
## @return A [code]Rect2[/code] representing the resized rectangle.
static func resized_rect_to_dimension(_original_rect: Rect2, _dimension: int) -> Rect2:
	var _resized_rect := Rect2()
	var _is_taller_than_larger: bool = _original_rect.size.x < _original_rect.size.y
	var ratio: float = float(_dimension)/_original_rect.size.y if _is_taller_than_larger else float(_dimension)/_original_rect.size.x
	_resized_rect.size = _original_rect.size * ratio
	return _resized_rect
#endregion


#region Warnings
func _get_configuration_warnings() -> PackedStringArray:
	var warnings = PackedStringArray()
	if not validate_items() and not suppress_warnings:
		warnings.append(
"""The 'items' list doesn't contain valid items.
If you add items using a script using RadialMenu.add_item(RadialMenuItem)
you can toggle 'suppress_warnings'"""
)
	return warnings
#endregion


##region Conditional properties
#func _validate_property(property: Dictionary) -> void:
	#if property.name == "dim_outer_radius" and dim_autosize == true:
		#property.usage |= PROPERTY_USAGE_READ_ONLY
##endregion
