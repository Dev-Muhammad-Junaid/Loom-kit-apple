//
//  MirageControlApp.swift
//  MirageControliOS
//

import LoomKit
import SwiftUI

@main
struct MirageControlApp: App {
    let loomContainer: LoomContainer

    init() {
        loomContainer = try! LoomContainer(
            for: LoomContainerConfiguration(
                serviceType: "_miragecontrol._tcp",
                serviceName: UIDevice.current.name,
                deviceIDSuiteName: "MirageControlLoomStore"
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentRootView()
                .loomContainer(loomContainer, autostart: false)
        }
    }
}
