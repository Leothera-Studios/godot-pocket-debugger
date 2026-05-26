extends Node

signal client_connected
signal client_disconnected

var tcp_server = TCPServer.new()
var connections = []
var next_id = 1
var is_running = false

var log_files = {}
var log_check_timer = null

func _ready():
	name = "CompanionHost"
	print("CompanionHost ready")

func enable_log_capture():
	print("Setting up log file monitoring...")
	
	var dir = DirAccess.open("user://")
	if dir and not dir.dir_exists("logs"):
		dir.make_dir("logs")
	
	if not ProjectSettings.get_setting("debug/file_logging/enable_file_logging", false):
		print("Enabling file logging automatically...")
		ProjectSettings.set_setting("debug/file_logging/enable_file_logging", true)
		ProjectSettings.save()
	
	var log_paths = [
		"user://logs/godot.log",
		"user://logs/godot-stdout.log",
		"user://godot.log"
	]
	
	for path in log_paths:
		log_files[path] = 0
	
	log_check_timer = Timer.new()
	log_check_timer.timeout.connect(_check_all_logs)
	log_check_timer.wait_time = 0.3
	add_child(log_check_timer)
	log_check_timer.start()
	
	print("Log monitoring active - checking every 0.3 seconds")

func disable_log_capture():
	if log_check_timer:
		log_check_timer.stop()
		log_check_timer.queue_free()
		log_check_timer = null

func start_server(port: int = 9080) -> bool:
	if is_running:
		return false
	
	var err = tcp_server.listen(port)
	if err != OK:
		print("Failed to start server: ", err)
		return false
	
	is_running = true
	print("Server listening on port ", port)
	return true

func stop_server():
	if not is_running:
		return
	
	is_running = false
	disable_log_capture()
	
	for conn in connections:
		if conn.socket:
			conn.socket.close()
	connections.clear()
	tcp_server.stop()
	print("Server stopped")

func _process(delta):
	if not is_running:
		return
	
	if tcp_server.is_connection_available():
		var socket = tcp_server.take_connection()
		if socket:
			var peer = WebSocketPeer.new()
			var err = peer.accept_stream(socket)
			if err == OK:
				var id = next_id
				next_id += 1
				connections.append({
					"id": id,
					"peer": peer,
					"socket": socket
				})
				emit_signal("client_connected", id)
				print("📱 Mobile Client ", id, " connected")
				
				_send_to_client(id, JSON.stringify({
					"type": "log",
					"log_type": "system",
					"content": "Connected to Godot Companion Host\nMonitoring console output...",
					"timestamp": Time.get_unix_time_from_system()
				}))
			else:
				print("Failed to accept WebSocket: ", err)
	
	for i in range(connections.size() - 1, -1, -1):
		var conn = connections[i]
		var peer = conn.peer
		peer.poll()
		
		var state = peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			emit_signal("client_disconnected", conn.id)
			connections.remove_at(i)
			print("Mobile Client ", conn.id, " disconnected")
			continue
		
		while peer.get_available_packet_count() > 0:
			var packet = peer.get_packet()
			var message = packet.get_string_from_utf8()
			_handle_message(conn.id, message)

func _check_all_logs():
	if not is_running:
		return
	
	for log_path in log_files.keys():
		_check_log_file(log_path)

func _check_log_file(log_path: String):
	if not FileAccess.file_exists(log_path):
		return
	
	var file = FileAccess.open(log_path, FileAccess.READ)
	if not file:
		return
	
	var current_pos = log_files[log_path]
	var file_size = file.get_length()
	
	if file_size > current_pos:
		file.seek(current_pos)
		var new_content = file.get_as_text()
		log_files[log_path] = file.get_position()
		file.close()
		
		# Process new lines
		var lines = new_content.split("\n")
		for line in lines:
			var trimmed = line.strip_edges()
			if trimmed != "":
				if _should_send_log(trimmed):
					var log_type = "print"
					if "ERROR" in trimmed or "error:" in trimmed.to_lower():
						log_type = "error"
					elif "WARNING" in trimmed or "warning:" in trimmed.to_lower():
						log_type = "warning"
					
					broadcast_log(trimmed, log_type)
	else:
		file.close()

func _should_send_log(line: String) -> bool:
	var skip_patterns = [
		"Godot Engine v",
		#"Vulkan",
		#"OpenGL",
		#"EditorFileSystem",
		#"--- Debug adapter server started",
		#"--- GDScript language server started",
		#"Script server started",
		#"Flushing cache"
	]
	
	for pattern in skip_patterns:
		if pattern in line:
			return false
	
	return true

func _handle_message(client_id: int, message: String):
	var json = JSON.new()
	var error = json.parse(message)
	
	if error != OK:
		return
	
	var data = json.data
	var command = data.get("command", "")
	
	match command:
		"get_profiler_data":
			_send_profiler_data(client_id)
		"ping":
			_send_to_client(client_id, JSON.stringify({
				"type": "pong",
				"timestamp": Time.get_unix_time_from_system()
			}))

func _send_profiler_data(client_id: int):
	var data = {
		"type": "profiler_data",
		"fps": Engine.get_frames_per_second(),
		"time_scale": Engine.time_scale,
		"process_time": Performance.get_monitor(Performance.TIME_PROCESS),
		"physics_time": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS),
		"memory_static": Performance.get_monitor(Performance.MEMORY_STATIC),
		"node_count": _get_node_count(),
		"timestamp": Time.get_unix_time_from_system()
	}
	
	_send_to_client(client_id, JSON.stringify(data))

func _get_node_count() -> int:
	if not is_instance_valid(get_tree()):
		return 0
	
	var count = 0
	var root = get_tree().root
	if root:
		count = _count_nodes_recursive(root)
	return count

func _count_nodes_recursive(node):
	var count = 1
	for child in node.get_children():
		count += _count_nodes_recursive(child)
	return count

func broadcast_log(text: String, log_type: String = "print"):
	if not is_running or connections.is_empty():
		return
	
	var message = JSON.stringify({
		"type": "log",
		"log_type": log_type,
		"content": text,
		"timestamp": Time.get_unix_time_from_system()
	})
	
	for conn in connections:
		_send_to_client(conn.id, message)

func _send_to_client(client_id: int, message: String):
	for conn in connections:
		if conn.id == client_id:
			var peer = conn.peer
			if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
				peer.send_text(message)
			break
