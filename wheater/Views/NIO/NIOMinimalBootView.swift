//
//  NIOMinimalBootView.swift
//  wheater
//
//  极简快启动画 v5.0
//  Logo 淡入 + 细进度线 + 轻量版本标，全程 ≤1.1s，无辉光克制风。
//  省电动效模式下为强制启用风格。
//

import SwiftUI

struct NIOMinimalBootView: View {
    @Binding var isFinished: Bool
    @ObservedObject private var themeService = AnimeThemeService.shared

    private var token: AnimeThemeToken { themeService.currentToken }
    private var text: Color { Color(hex: token.textPrimary) }
    private var textSoft: Color { Color(hex: token.textSecondary) }
    private var accent: Color { Color(hex: token.accentColor) }
    private var isDark: Bool { token.isDark }

    private var pace: NIOBootPace { NIOBootPace.current }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "5.0.0"
    }

    @State private var showLogo = false
    @State private var showName = false
    @State private var lineProgress: Double = 0.0
    @State private var scheduledWork = NIOScheduledWork()

    var body: some View {
        ZStack {
            Color(hex: token.backgroundPrimary)
                .ignoresSafeArea()

            NIOBootSkipOverlay(isFinished: $isFinished, visible: showName)
                .zIndex(10)

            VStack(spacing: 26) {
                Spacer()

                // Logo
                Image("NIO_brand")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 68, height: 68)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(accent.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(isDark ? 0.35 : 0.12), radius: 5)
                    .scaleEffect(showLogo ? 1.0 : 0.9)
                    .opacity(showLogo ? 1 : 0)

                // 名称
                Text("蔚来 · 兔可可")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(text)
                    .opacity(showName ? 1 : 0)
                    .offset(y: showName ? 0 : 6)

                // 细进度线
                Capsule()
                    .fill(accent.opacity(isDark ? 0.16 : 0.12))
                    .frame(width: 128, height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(
                                    LinearGradient(colors: [accent, textSoft], startPoint: .leading, endPoint: .trailing)
                                )
                                .frame(width: proxy.size.width * lineProgress)
                                .animation(.easeInOut(duration: 0.12), value: lineProgress)
                        }
                    }

                Spacer()

                Text("v\(appVersion) · YumikoToysRR")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(text.opacity(0.38))
                    .padding(.bottom, 24)
            }
        }
        .onAppear { runMinimalSequence() }
        .onDisappear { scheduledWork.cancelAll() }
    }

    // MARK: - 时序控制器

    private func runMinimalSequence() {
        // 1. Logo 淡入
        scheduledWork.schedule(after: 0.08) {
            withAnimation(.easeOut(duration: 0.32)) {
                showLogo = true
                showName = true
            }
        }

        // 2. 进度线快速充满
        scheduledWork.schedule(after: 0.22) {
            withAnimation(.easeInOut(duration: pace.t(0.55))) {
                lineProgress = 1.0
            }
        }

        // 3. 直达看板（全程 ≤1.1s）
        scheduledWork.schedule(after: pace.t(0.95)) {
            withAnimation(.easeInOut(duration: 0.25)) {
                isFinished = true
            }
        }
    }
}
