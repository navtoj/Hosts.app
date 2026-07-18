#!/usr/bin/env swift

import SwiftUI

struct Hosts: App {
	var body: some Scene {
		Window("Hosts", id: "Hosts") {
			Text("/etc/hosts")
				.frame(width: 120, height: 50)
				.fixedSize()
		}
		.windowResizability(.contentSize)
	}
}

Hosts.main()
