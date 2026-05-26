extends Control

# Your existing UI nodes
@onready var connect_button = $VBoxContainer/HBox/ConnectButton
@onready var status_label = $VBoxContainer/HBox/StatusLabel
@onready var log_display = $VBoxContainer/LogDisplay
@onready var share_button: Button = $VBoxContainer/ShareButton
@onready var ip_field: LineEdit = $VBoxContainer/IpField
@onready var fps_label: Label = $VBoxContainer/PerformancePanel/FPSLabel
@onready var memory_label: Label = $VBoxContainer/PerformancePanel/MemoryLabel
@onready var node_count_label: Label = $VBoxContainer/PerformancePanel/NodeCountLabel

var websocket = WebSocketPeer.new()
var connected = false
var logs = []
var MAX_LOGS = 500
var is_fully_connected = false
var connection_attempt_time = 0
var connection_timeout = 5.0
var HOST = "192.168.8.88"
const PORT = 9080

# Rate limiting
var last_request_time = 0
var request_cooldown = 1.0

func _ready():
	connect_button.pressed.connect(_toggle_connection)
	share_button.pressed.connect(_share_logs)
	update_status("Disconnected")
	
	log_display.text = ""
	
	if OS.get_name() == "Android":
		_request_internet_permission()

func _toggle_connection():
	if connected:
		disconnect_from_host()
	else:
		HOST = ip_field.text if !ip_field.text.is_empty() else "192.168.0.100"
		connect_to_host()

func connect_to_host():
	var url = "ws://" + HOST + ":" + str(PORT)
	
	websocket = WebSocketPeer.new()
	
	var err = websocket.connect_to_url(url)
	
	connected = true
	is_fully_connected = false
	connection_attempt_time = Time.get_ticks_msec() / 1000.0
	last_request_time = 0
	update_status("Connecting...")
	add_log("Connecting to " + url, "system")

func disconnect_from_host():
	websocket.close()
	connected = false
	is_fully_connected = false
	update_status("Disconnected")
	add_log("Disconnected from host", "system")

func _process(delta):
	connect_button.text = "Connect" if !connected else "Disconnect"
	if not connected:
		return
	websocket.poll()
	
	var state = websocket.get_ready_state()
	var current_time = Time.get_ticks_msec() / 1000.0
	
	match state:
		WebSocketPeer.STATE_OPEN:
			if not is_fully_connected:
				is_fully_connected = true
				update_status("Connected")
				add_log("Connected to host!", "system")
				last_request_time = current_time
			
			while websocket.get_available_packet_count() > 0:
				var packet = websocket.get_packet()
				var message = packet.get_string_from_utf8()
				_handle_message(message)
			
			if current_time - last_request_time >= request_cooldown:
				last_request_time = current_time
				_request_profiler_data()
		
		WebSocketPeer.STATE_CONNECTING:
			if current_time - connection_attempt_time > connection_timeout:
				connected = false
				update_status("Connection Timeout")
				add_log("Connection timeout - check if host is running", "error")
				websocket.close()
		
		WebSocketPeer.STATE_CLOSED:
			if is_fully_connected:
				is_fully_connected = false
				connected = false
				update_status("Disconnected")
				add_log("Connection closed by host", "system")
			elif connected and not is_fully_connected:
				connected = false
				update_status("Connection Failed")
				var close_code = websocket.get_close_code()
				add_log("Connection failed (Code: " + str(close_code) + ")", "error")
				add_log("   Check that:", "system")
				add_log("   1. PC Host is running (Start Companion Host)", "system")
				add_log("   2. HOST IP is correct: " + HOST, "system")
				add_log("   3. Both devices on same WiFi", "system")
				add_log("   4. No firewall blocking port " + str(PORT), "system")

func _request_profiler_data():
	if websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var command = JSON.stringify({"command": "get_profiler_data"})
		websocket.send_text(command)

func _handle_message(message: String):
	var json = JSON.new()
	var parse_result = json.parse(message)
	
	if parse_result != OK:
		return
	
	var data = json.data
	var msg_type = data.get("type", "")
	
	match msg_type:
		"log":
			add_log(data.get("content", ""), data.get("log_type", "print"))
		"error":
			add_error_log(data)
		"node_info":
			display_node_info(data)
		"profiler_data":
			update_performance_display(data)
		"pong":
			pass
		"error_response":
			add_log("Server error: " + data.get("message", ""), "error")

func _format_bytes(bytes):
	if bytes < 1024:
		return str(bytes) + " B"
	elif bytes < 1024 * 1024:
		return str(bytes / 1024).pad_decimals(1) + " KB"
	else:
		return str(bytes / (1024 * 1024)).pad_decimals(1) + " MB"

func update_performance_display(data):
	fps_label.text = "FPS: " + str(data.get("fps", 0))
	memory_label.text = "Memory: " + _format_bytes(data.get("memory_static", 0))
	node_count_label.text = "Nodes: " + str(data.get("node_count", 0))

func display_node_info(node_data):
	add_log("=== Node Info: %s ===" % node_data.get("path", "unknown"), "system")
	add_log("Class: " + node_data.get("class", "unknown"), "system")
	add_log("Properties:", "system")
	for prop in node_data.get("properties", {}):
		add_log("  %s: %s" % [prop, node_data["properties"][prop]], "system")

func add_log(text: String, log_type: String = "print"):
	var timestamp = Time.get_time_string_from_system()
	var log_entry = "[%s] %s" % [timestamp, text]
	
	if "Godot Engine" not in log_entry:
		logs.append({"text": log_entry, "type": log_type, "timestamp": Time.get_unix_time_from_system()})
	
	while logs.size() > MAX_LOGS:
		logs.pop_front()
	
	log_display.text += log_entry + "\n"
	
	log_display.set_caret_line(log_display.get_line_count() - 1)

func add_error_log(error_data):
	var error_msg = "ERROR: " + error_data.get("message", "Unknown error")
	add_log(error_msg, "error")
	
	if error_data.has("node_info"):
		add_log("  Node properties:", "system")
		for key in error_data.node_info:
			add_log("    %s: %s" % [key, error_data.node_info[key]], "system")

func update_status(status: String):
	status_label.text = "Status: " + status
	match status:
		"Connected":
			status_label.modulate = Color.GREEN
		"Disconnected":
			status_label.modulate = Color.RED
		_:
			status_label.modulate = Color.YELLOW

func _share_logs():
	if logs.is_empty():
		add_log("No logs to share", "warning")
		return
	
	var share_text = "=== Godot Debug Logs ===\n"
	share_text += "Exported: " + Time.get_datetime_string_from_system() + "\n\n"
	
	var logs_to_share = logs.slice(max(0, logs.size() - 100), logs.size() - 1)
	for log in logs_to_share:
		share_text += log["text"] + "\n"
	
	if OS.get_name() == "Android":
		DisplayServer.clipboard_set(share_text)
		add_log("Logs copied to clipboard", "system")
	elif OS.get_name() == "iOS":
		DisplayServer.clipboard_set(share_text)
		add_log("Logs copied to clipboard", "system")
	else:
		DisplayServer.clipboard_set(share_text)
		add_log("Logs copied to clipboard", "system")

func _request_internet_permission():
	pass
