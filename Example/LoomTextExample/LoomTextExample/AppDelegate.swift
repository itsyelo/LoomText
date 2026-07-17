//
//  AppDelegate.swift
//  LoomTextExample
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let tabs = UITabBarController()
        tabs.viewControllers = [
            UINavigationController(rootViewController: ShowcaseViewController()).withTab(
                title: "Showcase", systemImage: "textformat"
            ),
            UINavigationController(rootViewController: FeedViewController()).withTab(
                title: "Loom Feed", systemImage: "list.bullet.rectangle"
            ),
            UINavigationController(rootViewController: ChatViewController()).withTab(
                title: "Chat", systemImage: "bubble.left.and.bubble.right"
            ),
            UINavigationController(rootViewController: PerfViewController()).withTab(
                title: "Perf", systemImage: "speedometer"
            ),
        ]

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

private extension UIViewController {
    func withTab(title: String, systemImage: String) -> UIViewController {
        tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: systemImage), tag: 0)
        return self
    }
}
