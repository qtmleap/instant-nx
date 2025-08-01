//
//  mainApp.swift
//  InstantNX
//
//  Created by devonly on 2024/10/12.
//

import FirebaseCore
import QuantumLeap
import SwiftUI

// MARK: - mainApp

@main
struct mainApp: App {
    // MARK: Internal

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(NXClient())
                .environmentIsFirstLaunch()
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, UIApplicationDelegate, UIWindowSceneDelegate {
    func application(
        _: UIApplication,
        willFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool { true }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        Logger.configure()
        FirebaseApp.configure()
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = AppDelegate.self
        return config
    }

    func scene(_: UIScene, openURLContexts _: Set<UIOpenURLContext>) {}

    func scene(
        _: UIScene,
        willConnectTo _: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) {}

    func sceneDidBecomeActive(_: UIScene) {}
}
