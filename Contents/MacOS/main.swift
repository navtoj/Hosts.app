#!/usr/bin/env swift

import SwiftUI

// MARK: - HostEntry

struct HostEntry: Identifiable {
	let id = UUID()
	var raw: String
	var enabled: Bool
	var ip: String
	var hostnames: String
	var comment: String
	var isEntry: Bool
}

func looksLikeIpAddress(_ token: String) -> Bool {
	if token.isEmpty {
		return false
	}
	let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
	guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
	
	return token.contains(where: \.isNumber)
}

func parseLine(_ line: String) -> HostEntry {
	let trimmed = line.trimmingCharacters(in: .whitespaces)
	if trimmed.isEmpty {
		return HostEntry(
			raw: line,
			enabled: true,
			ip: "",
			hostnames: "",
			comment: "",
			isEntry: false
		)
	}
	
	var working = trimmed
	var enabled = true
	if working.hasPrefix("#") {
		enabled = false
		working.removeFirst()
		working = working.trimmingCharacters(in: .whitespaces)
	}
	
	var content = working
	var comment = ""
	if let hashIndex = working.firstIndex(of: "#") {
		content = String(working[working.startIndex ..< hashIndex]).trimmingCharacters(in: .whitespaces)
		comment = String(working[working.index(after: hashIndex)...]).trimmingCharacters(in: .whitespaces)
	}
	
	let tokens = content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
	if tokens.count >= 2, looksLikeIpAddress(tokens[0]) {
		let ip = tokens[0]
		let hostnames = tokens[1...].joined(separator: " ")
		return HostEntry(
			raw: line,
			enabled: enabled,
			ip: ip,
			hostnames: hostnames,
			comment: comment,
			isEntry: true
		)
	}
	
	return HostEntry(raw: line, enabled: true, ip: "", hostnames: "", comment: "", isEntry: false)
}

func parseFile(_ content: String) -> [HostEntry] {
	content.trimmingCharacters(in: .newlines).components(separatedBy: "\n").map(parseLine)
}

func serializeFile(_ entries: [HostEntry]) -> String {
	var lines = [String]()
	for entry in entries {
		if entry.isEntry {
			var line = ""
			line += entry.ip
			line += "\t"
			line += entry.hostnames
			if !entry.comment.isEmpty {
				line += " # " + entry.comment
			}
			var trimmed = line.trimmingCharacters(in: .whitespaces)
			if !entry.enabled, !trimmed.starts(with: "#") {
				trimmed = "# " + trimmed
			}
			lines.append(trimmed)
		} else {
			lines.append(entry.raw)
		}
	}
	return lines.joined(separator: "\n") + "\n"
}

let filePath = "/etc/hosts"
func loadFile() throws -> String {
	try String(contentsOfFile: filePath, encoding: .utf8)
		.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
}

// MARK: - SaveError

enum SaveError: Error {
	case couldNotWriteTempFile(Error)
	case couldNotCreateScript
	case couldNotRunScript(String?)
	
	// MARK: Computed Properties
	
	var errorDescription: String {
		switch self {
			case let .couldNotWriteTempFile(error):
				"Failed to write temp file. \(error.localizedDescription)"
			case .couldNotCreateScript:
				"Failed to create AppleScript."
			case let .couldNotRunScript(message):
				"Failed to run AppleScript. \(message ?? "Unknown error.")"
		}
	}
}

func saveFile(_ content: String) -> Result<Void, SaveError> {
	let tempPath = NSTemporaryDirectory() + "hosts_\(UUID().uuidString).tmp"
	do {
		try content
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.write(toFile: tempPath, atomically: true, encoding: .utf8)
	} catch {
		return .failure(.couldNotWriteTempFile(error))
	}
	defer {
		try? FileManager.default.removeItem(atPath: tempPath)
	}
	
	let command = """
	set -e
	cp \(filePath) \(filePath).app
	cp '\(tempPath)' \(filePath)
	chown root:wheel \(filePath) \(filePath).app
	chmod 644 \(filePath) \(filePath).app
	dscacheutil -flushcache
	killall -HUP mDNSResponder 2>/dev/null || true
	"""
	.replacing("\\", with: "\\\\")
	.replacing("\"", with: "\\\"")
	.replacing("\n", with: "\\n")
	
	let appleScript = "do shell script \"\(command)\" with administrator privileges"
	guard let script = NSAppleScript(source: appleScript) else {
		return .failure(.couldNotCreateScript)
	}
	
	var errorDict: NSDictionary?
	script.executeAndReturnError(&errorDict)
	if let errorDict {
		let message = errorDict[NSAppleScript.errorMessage] as? String
		return .failure(.couldNotRunScript(message))
	}
	
	return .success(())
}

// MARK: - HostRow

struct HostRow: View {
	// MARK: SwiftUI Properties
	
	@Binding var entry: HostEntry
	
	// MARK: Properties
	
	var onDelete: () -> Void
	var focused: FocusState<UUID?>.Binding
	
	// MARK: Content Properties
	
	var body: some View {
		if entry.isEntry {
			HStack(spacing: 8) {
				Toggle("", isOn: $entry.enabled)
					.labelsHidden()
				TextField("IP Address", text: $entry.ip)
					.textFieldStyle(.roundedBorder)
					.frame(width: 140)
					.focused(focused, equals: entry.id)
				TextField("Hostnames", text: $entry.hostnames)
					.textFieldStyle(.roundedBorder)
				TextField("Comment", text: $entry.comment)
					.textFieldStyle(.roundedBorder)
					.frame(width: 140)
				Button(role: .destructive, action: onDelete) {
					Image(systemName: "trash")
				}
				.buttonStyle(.borderless)
			}
			.opacity(entry.enabled ? 1.0 : 0.45)
		} else {
			HStack {
				Text(entry.raw.isEmpty ? "" : entry.raw)
					.font(.system(.body, design: .monospaced))
					.foregroundColor(.secondary)
					.lineLimit(1)
				Spacer()
				Button(role: .destructive, action: onDelete) {
					Image(systemName: "trash")
				}
				.buttonStyle(.borderless)
			}
		}
	}
}

// MARK: - ContentView

struct ContentView: View {
	// MARK: SwiftUI Properties
	
	@State private var entries = [HostEntry]()
	@State private var status = ""
	@State private var isError = false
	@State private var original = ""
	
	@FocusState private var focused: UUID?
	
	// MARK: Computed Properties
	
	var changed: Bool {
		original != serializeFile(entries)
	}
	
	var isLastEntryNew: Bool {
		guard let last = entries.last else { return false }
		
		return last.enabled && last.isEntry && (last.ip.isEmpty || last.hostnames.isEmpty)
	}
	
	// MARK: Content Properties
	
	var body: some View {
		VStack(spacing: 0) {
			List {
				ForEach($entries) { $entry in
					HostRow(entry: $entry, onDelete: { delete(entry) }, focused: $focused)
				}
			}
			.listStyle(.inset(alternatesRowBackgrounds: true))
			if !status.isEmpty {
				Divider()
				Text(status)
					.font(.callout)
					.foregroundColor(isError ? .red : .secondary)
					.padding(10)
					.frame(maxWidth: .infinity, alignment: .center)
			}
		}
		.onAppear(perform: reload)
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				Button(action: reload) {
					Label("Reload", systemImage: "arrow.clockwise")
				}
				Button(action: add) {
					Label("Add", systemImage: "plus")
				}
				.disabled(isLastEntryNew)
				Button(action: save) {
					Text("Save")
						.padding(.horizontal, 4)
				}
				.keyboardShortcut("s", modifiers: .command)
				.disabled(!changed || isLastEntryNew)
			}
		}
	}
	
	// MARK: Functions
	
	func reload() {
		do {
			let content = try loadFile()
			entries = parseFile(content)
			original = serializeFile(entries)
			status = "Loaded \(entries.count(where: { $0.isEntry })) entries."
			isError = false
		} catch {
			entries = []
			original = ""
			status = "Could not read file. \(error.localizedDescription)"
				.trimmingCharacters(in: .whitespacesAndNewlines)
			isError = true
		}
	}
	
	func add() {
		let entry = HostEntry(
			raw: "",
			enabled: true,
			ip: "",
			hostnames: "",
			comment: "",
			isEntry: true
		)
		entries.append(entry)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			focused = entry.id
		}
	}
	
	func delete(_ entry: HostEntry) {
		entries.removeAll { $0.id == entry.id }
	}
	
	func save() {
		guard let file = try? loadFile(), file == original else {
			status = "File has changed on disk. Please reload."
			isError = true
			return
		}
		
		if let entry = entries.first(where: { $0.isEntry && $0.enabled && !looksLikeIpAddress($0.ip) }) {
			status = "IP address '\(entry.ip)' is not valid."
			isError = true
			return
		}
		
		let content = serializeFile(entries)
		switch saveFile(content) {
			case .success:
				reload()
			case let .failure(error):
				status = "Could not update file. \(error.localizedDescription)"
					.trimmingCharacters(in: .whitespacesAndNewlines)
				isError = true
		}
	}
}

// MARK: - WindowBehavior

struct WindowBehavior: NSViewRepresentable {
	func makeNSView(context _: Context) -> NSView {
		DispatchQueue.main.async {
			if let window = NSApp.windows.first {
				window.center()
				window.collectionBehavior.insert(.moveToActiveSpace)
			}
		}
		return NSView()
	}
	
	func updateNSView(_: NSView, context _: Context) {}
}

// MARK: - Hosts

struct Hosts: App {
	var body: some Scene {
		Window(filePath, id: "Hosts") {
			ContentView()
				.background(WindowBehavior())
				.frame(minWidth: 560, minHeight: 420)
		}
		.windowResizability(.contentSize)
		.commands {
			CommandGroup(replacing: .appInfo) {
				Button("About Hosts") {
					if let link = URL(string: "https://github.com/navtoj/Hosts.app") {
						NSWorkspace.shared.open(link)
					}
				}
			}
			CommandGroup(replacing: .systemServices) {}
			CommandGroup(replacing: .appVisibility) {}
			CommandGroup(replacing: .appTermination) {
				Button("Quit App") {
					NSApplication.shared.terminate(nil)
				}.keyboardShortcut("q")
			}
			CommandGroup(replacing: .help) {}
			CommandGroup(replacing: .textEditing) {}
		}
	}
}

Hosts.main()
