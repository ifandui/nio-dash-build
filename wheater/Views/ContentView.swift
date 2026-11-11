//
//  ContentView.swift
//  wheater
//
//  NIO vehicle dashboard entry point
//

import SwiftUI

struct ContentView: View {
    @State private var isSplashFinished = false
    @ObservedObject private var themeService = AnimeThemeService.shared

    var body: some View {
        ZStack {
            IOSNIODashboardView()

            if !isSplashFinished {
                NIOLaunchSplashView(isFinished: $isSplashFinished)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: isSplashFinished)
        .animation(.easeInOut(duration: 0.28), value: themeService.currentStyle)
        .tint(themeService.accentColor())
        .preferredColorScheme(themeService.currentToken.isDark ? .dark : .light)
    }
}
