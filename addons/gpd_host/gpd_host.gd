@tool
extends EditorPlugin

var is_running = false
var websocket_server = null

func _enter_tree():
	add_tool_menu_item("Start Companion Host", _toggle_host)
	print("Companion Host addon loaded")

func _exit_tree():
	remove_tool_menu_item("Start Companion Host")
	
	if is_running:
		_stop_server()
	
	print("Companion Host addon unloaded")

func _toggle_host():
	if is_running:
		_stop_server()
	else:
		_start_server()

func _start_server():
	# Create the server instance directly
	websocket_server = preload("res://addons/gpd_host/scripts/script_websocket_server.gd").new()
	
	# Add it as a child
	add_child(websocket_server)
	
	var success = websocket_server.start_server(9080)
	if success:
		is_running = true
		print("Companion Host running on port 9080")
		websocket_server.enable_log_capture()
		
		# Update menu text
		remove_tool_menu_item("Start Companion Host")
		add_tool_menu_item("Stop Companion Host", _toggle_host)
	else:
		print("Failed to start server")
		websocket_server.queue_free()
		websocket_server = null

func _stop_server():
	if websocket_server:
		websocket_server.stop_server()
		websocket_server.queue_free()
		websocket_server = null
	
	is_running = false
	print("Companion Host stopped")
	
	# Update menu text
	remove_tool_menu_item("Stop Companion Host")
	add_tool_menu_item("Start Companion Host", _toggle_host)

func _handles(object):
	return false
