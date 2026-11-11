//
//  IOSNIOConfigView.swift
//  wheater
//
//  蔚来看板 iOS 配置与设置界面（二次元萌动科技风 🌸🐰✨）
//

import SwiftUI
import PhotosUI

@MainActor
struct IOSNIOConfigView: View {
    @ObservedObject var service = NIOService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var smartInput = ""
    @State private var showSuccessBanner = false
    @State private var bannerWork = NIOScheduledWork()
    // 后台定位保活：状态观察 + 开关（默认开）
    @ObservedObject private var keepAlive = NIOLocationKeepAlive.shared
    @AppStorage("nio_location_keepalive") private var keepAliveEnabled = true
    @State private var testStatusText: String?
    @State private var isTesting = false
    @State private var showLogsSheet = false
    @State private var showInboxSheet = false
    @State private var showAboutSheet = false
    @State private var showReleaseNotesSheet = false
    @State private var showLaunchPreview = false
    @AppStorage("nio_prefer_actual_range") private var preferActualRange = false
    @ObservedObject private var themeService = AnimeThemeService.shared
    @ObservedObject private var vpnManager = NIOVPNManager.shared
    @ObservedObject private var certManager = NIOVPNCertManager.shared
    @ObservedObject private var receiver = NIOCredentialReceiver.shared
    @AppStorage("nio_vehicle_selected_model") private var selectedModelSlug = "et5_special"
    @AppStorage("nio_vehicle_selected_color") private var selectedColorSlug = "nature_wonder"
    // 首页名称与车型图片（v5.1）
    @AppStorage("nio_home_title") private var homeTitle = "兔可可·蔚来"
    @AppStorage("nio_hero_photo_mode") private var heroPhotoModeRaw = NIOHeroPhotoMode.gradient.rawValue
    @State private var heroPhotoItem: PhotosPickerItem?
    @State private var heroPhotoHint: String?

    // 二次元萌系主题色（跟随全局主题实时刷新）
    private var sakuraPink: Color { themeService.accentColor() }
    private var lavenderDream: Color { Color(hex: themeService.currentToken.gradientEnd) }
    private var mintCyan: Color { themeService.glowColor() }
    private var pastelYellow: Color { themeService.warmAccentColor() }
    // 省电动效（关闭流光 / 浮动等常驻动画）
    @AppStorage("nio_reduced_fx") private var reducedFx = false

    var body: some View {
        NavigationStack {
            ZStack {
                // 背景渐变
                animeBackground
                    .ignoresSafeArea()

                // 应用内横幅：在设置页停留时也能看到推送回填 / 刷新结果
                .overlay(alignment: .top) {
                    if let notice = service.transientNotice {
                        NIOTransientNoticeBanner(notice: notice) {
                            service.transientNotice = nil
                        }
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: service.transientNotice)

                GeometryReader { geo in
                    // Duo 展开态 / iPad 宽屏：设置双列（视觉设置左，连接与 API 右）；窄屏单列
                    let twoColumns = geo.size.width >= 780

                    ScrollView(showsIndicators: false) {
                        Group {
                            if twoColumns {
                                HStack(alignment: .top, spacing: 16) {
                                    VStack(spacing: 16) {
                                        configHeaderView
                                        themeSelectorCard
                                        launchAnimationCard
                                        carModelSelectorCard
                                    }
                                    .frame(maxWidth: .infinity, alignment: .top)

                                    VStack(spacing: 16) {
                                        shadowrocketPushCard
                                        inAppVpnSnifferCard
                                        smartParseCard
                                        vehicleApiCard
                                        extraServicesCard
                                        scheduleAndTestCard
                                        sniffGuideCard
                                        aboutAndLogsSection
                                    }
                                    .frame(maxWidth: .infinity, alignment: .top)
                                }
                            } else {
                                VStack(spacing: 16) {
                                    // 1. 顶部 Header
                                    configHeaderView

                                    // 2. 🎨 动漫主题风格与粒子特效
                                    themeSelectorCard

                                    // 2.5 🚀 启动动画风格与节奏
                                    launchAnimationCard

                                    // 3. 🚘 爱车车型与车漆涂装定制
                                    carModelSelectorCard

                                    // 3.5 🚀 Shadowrocket 直推（推荐方案）
                                    shadowrocketPushCard

                                    // 3.6 🔌 内置 TCP 转发（兜底）
                                    inAppVpnSnifferCard

                                    // 4. ⚡️ 智能识别与一键填充
                                    smartParseCard

                                    // 4.5 💾 备份与恢复（重装迁移）
                                    NavigationLink {
                                        NIOConfigBackupView()
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "externaldrive.badge.timemachine")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(mintCyan)
                                                .frame(width: 22)
                                            Text("备份与恢复（重装迁移）")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(NIOThemePaint.text)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(14)
                                        .background(NIOThemePaint.well)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                    .buttonStyle(.plain)

                                    // 5. 🚗 核心车辆 API (必填)
                                    vehicleApiCard

                                    // 6. 📑 扩展服务 (换电 & 签到)
                                    extraServicesCard

                                    // 7. ⏱️ 调度与连通性测试
                                    scheduleAndTestCard

                                    // 8. 📱 抓取指引
                                    sniffGuideCard

                                    // 9. 🌸 软件关于与诊断
                                    aboutAndLogsSection

                                    Spacer(minLength: 24)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        // 大屏双列放宽限宽；窄屏保持紧凑单列
                        .frame(maxWidth: twoColumns ? 1100 : 640)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("蔚来看板设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(themeService.backgroundPrimary(), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(sakuraPink)
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button(action: { showReleaseNotesSheet = true }) {
                            Image(systemName: "sparkles.rectangle.stack.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(pastelYellow)
                        }

                        Button(action: { showLogsSheet = true }) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(mintCyan)
                        }

                        Button(action: { showAboutSheet = true }) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(lavenderDream)
                        }
                    }
                }
            }
            .adaptivePresentation(isPresented: $showLogsSheet) {
                IOSNIOFetchLogView()
            }
            .adaptivePresentation(isPresented: $showInboxSheet) {
                NIOCredentialInboxView()
            }
            .adaptivePresentation(isPresented: $showAboutSheet) {
                IOSAboutView()
            }
            .adaptivePresentation(isPresented: $showReleaseNotesSheet) {
                IOSReleaseNotesView()
            }
            .fullScreenCover(isPresented: $showLaunchPreview) {
                NIOLaunchPreviewHost(isPresented: $showLaunchPreview)
            }
            .onChange(of: heroPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        // 压缩存储，控制沙盒体积
                        if let jpeg = image.jpegData(compressionQuality: 0.85) {
                            try? NIOHeroPhotoStore.save(data: jpeg)
                            heroPhotoHint = "✅ 已导入，主页将显示自定义车型图"
                        } else {
                            heroPhotoHint = "⚠️ 图片格式无法识别"
                        }
                    } else {
                        heroPhotoHint = "⚠️ 图片读取失败，请重试"
                    }
                    heroPhotoItem = nil
                }
            }
        }
    }

    // MARK: - 1. 顶部 Header

    private var configHeaderView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [sakuraPink, lavenderDream], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .shadow(color: sakuraPink.opacity(0.4), radius: 8)

                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(NIOThemePaint.text)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("参数与同步配置")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(NIOThemePaint.text)
                Text("配置蔚来 API Token 与灵动岛实时监控调度")
                    .font(.system(size: 11))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.6))
            }
            Spacer()
        }
        .padding(12)
        .background(NIOThemePaint.fill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 2. 🎨 主题风格卡片（三系七主题 · 分类分组 + 色板预览）

    private var themeSelectorCard: some View {
        cardContainer(title: "🎨 主题外观风格", icon: "paintpalette.fill", accentColor: sakuraPink) {
            VStack(alignment: .leading, spacing: 12) {
                Text("七大主题 · 二次元 / 简洁 / 酷，浅色深色全适配，灵动岛同步换装：")
                    .font(.system(size: 11))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.7))

                ForEach(AnimeThemeCategory.allCases) { category in
                    let styles = AnimeThemeStyle.allCases.filter { $0.category == category }

                    VStack(alignment: .leading, spacing: 8) {
                        // 分类标题
                        HStack(spacing: 5) {
                            Image(systemName: category.categoryIcon)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(sakuraPink)
                            Text(category.displayName)
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundStyle(NIOThemePaint.text.opacity(0.75))
                            Rectangle()
                                .fill(NIOThemePaint.stroke)
                                .frame(height: 0.8)
                        }

                        // 主题色板网格（自适应列数：窄 2 列 / 宽 3 列）
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                            ForEach(styles) { style in
                                themeSwatchButton(style)
                            }
                        }
                    }
                }

                // 省电动效开关
                Toggle(isOn: $reducedFx) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("🔋 省电动效模式")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NIOThemePaint.text)
                        Text("关闭流光能量槽、车辆浮动等常驻动画，降低耗电与 GPU 占用")
                            .font(.system(size: 9))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.55))
                    }
                }
                .tint(sakuraPink)
            }
        }
    }

    /// 单个主题色板选择按钮（渐变预览球 + 名称 + 浅/深标记）
    private func themeSwatchButton(_ style: AnimeThemeStyle) -> some View {
        let isSelected = (themeService.currentStyle == style)
        let token = AnimeThemeToken.preset(named: style.rawValue)

        return Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                themeService.setStyle(style)
            }
        }) {
            VStack(spacing: 5) {
                // 渐变色板预览球
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: token.gradientStart), Color(hex: token.gradientEnd)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                        .shadow(color: Color(hex: token.accentColor).opacity(isSelected ? 0.55 : 0.25), radius: isSelected ? 7 : 4)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.top, 2)

                // 名称
                Text(style.displayName)
                    .font(.system(size: 10, weight: isSelected ? .heavy : .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? sakuraPink : NIOThemePaint.text.opacity(0.8))
                    .lineLimit(1)

                // 浅 / 深标记
                Text(token.isDark ? "深色" : "浅色")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(token.isDark ? Color.black.opacity(0.35) : sakuraPink.opacity(0.14))
                    .foregroundStyle(token.isDark ? NIOThemePaint.text.opacity(0.65) : sakuraPink)
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .background(isSelected ? sakuraPink.opacity(0.12) : NIOThemePaint.fill)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? sakuraPink.opacity(0.7) : NIOThemePaint.stroke, lineWidth: isSelected ? 1.2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.category.displayName)主题 \(style.displayName)")
    }

    // MARK: - 2.5 🚀 启动动画风格卡片（三风格 + 节奏 + 每日一次 + 触感 + 预览）

    @AppStorage(NIOBootSettings.styleKey) private var bootStyleRaw = NIOBootStyle.energyCharge.rawValue
    @AppStorage(NIOBootSettings.paceKey) private var bootPaceRaw = NIOBootPace.standard.rawValue
    @AppStorage(NIOBootSettings.dailyOnceKey) private var bootDailyOnce = false
    @AppStorage(NIOBootSettings.hapticsKey) private var bootHaptics = true

    private var launchAnimationCard: some View {
        cardContainer(title: "🚀 启动动画风格", icon: "rocket.launch.fill", accentColor: pastelYellow) {
            VStack(alignment: .leading, spacing: 12) {
                Text("三套开屏风格 · 省电动效模式下自动切换为极简快启：")
                    .font(.system(size: 11))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.7))

                // 风格三选
                HStack(spacing: 8) {
                    ForEach(NIOBootStyle.allCases) { style in
                        bootStyleButton(style)
                    }
                }

                // 节奏选择
                HStack(spacing: 8) {
                    Text("节奏")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(NIOThemePaint.text)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(NIOBootPace.allCases) { pace in
                            Button {
                                NIOBootHaptics.impact(.light)
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    bootPaceRaw = pace.rawValue
                                }
                            } label: {
                                Text(pace.displayName)
                                    .font(.system(size: 11, weight: bootPaceRaw == pace.rawValue ? .heavy : .semibold, design: .rounded))
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 5)
                                    .background(bootPaceRaw == pace.rawValue ? pastelYellow.opacity(0.18) : NIOThemePaint.fill)
                                    .foregroundStyle(bootPaceRaw == pace.rawValue ? pastelYellow : NIOThemePaint.text.opacity(0.6))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(bootPaceRaw == pace.rawValue ? pastelYellow.opacity(0.6) : NIOThemePaint.stroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // 每日一次开关
                Toggle(isOn: $bootDailyOnce) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("🌅 每日仅首次展示")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NIOThemePaint.text)
                        Text("当天再次打开 App 时跳过动画，直达看板")
                            .font(.system(size: 9))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.55))
                    }
                }
                .tint(sakuraPink)

                // 触感开关
                Toggle(isOn: $bootHaptics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("📳 开屏触感反馈")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NIOThemePaint.text)
                        Text("Logo 亮起瞬间的轻微振动提示")
                            .font(.system(size: 9))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.55))
                    }
                }
                .tint(sakuraPink)

                // 预览按钮
                Button {
                    NIOBootHaptics.impact(.light)
                    showLaunchPreview = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("预览启动动画")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.4))
                    }
                    .foregroundStyle(sakuraPink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(sakuraPink.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 单个启动风格选择按钮
    private func bootStyleButton(_ style: NIOBootStyle) -> some View {
        let isSelected = (bootStyleRaw == style.rawValue)

        return Button {
            NIOBootHaptics.impact(.light)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                bootStyleRaw = style.rawValue
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [sakuraPink.opacity(isSelected ? 0.22 : 0.08), lavenderDream.opacity(isSelected ? 0.16 : 0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)

                    Image(systemName: style.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? sakuraPink : NIOThemePaint.text.opacity(0.55))
                }

                Text(style.displayName)
                    .font(.system(size: 10, weight: isSelected ? .heavy : .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? sakuraPink : NIOThemePaint.text.opacity(0.8))
                    .lineLimit(1)

                Text(style.styleDescription)
                    .font(.system(size: 8))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .background(isSelected ? sakuraPink.opacity(0.1) : NIOThemePaint.fill)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? sakuraPink.opacity(0.7) : NIOThemePaint.stroke, lineWidth: isSelected ? 1.2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("启动动画风格 \(style.displayName)")
    }

    // MARK: - 3. 🚘 爱车车型与涂装配置卡片

    private var carModelSelectorCard: some View {
        cardContainer(title: "🚘 爱车车型与涂装车漆", icon: "car.side.fill", accentColor: pastelYellow) {
            VStack(alignment: .leading, spacing: 12) {
                // 首页名称自定义
                HStack(spacing: 10) {
                    Text("首页名称")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(NIOThemePaint.text)
                    Spacer(minLength: 12)
                    TextField("NIO", text: $homeTitle, prompt: Text("NIO").foregroundStyle(NIOThemePaint.text.opacity(0.35)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(pastelYellow)
                        .tint(pastelYellow)
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .frame(width: 120)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(NIOThemePaint.fill)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(NIOThemePaint.stroke, lineWidth: 1))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("看板首页左上角标题")

                // 车型图片来源
                VStack(alignment: .leading, spacing: 8) {
                    Text("主页车型图片")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(NIOThemePaint.text)

                    HStack(spacing: 6) {
                        ForEach(NIOHeroPhotoMode.allCases) { mode in
                            let isSelected = (heroPhotoModeRaw == mode.rawValue)
                            Button {
                                NIOBootHaptics.impact(.light)
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    heroPhotoModeRaw = mode.rawValue
                                }
                            } label: {
                                Text(mode.displayName)
                                    .font(.system(size: 11, weight: isSelected ? .heavy : .semibold, design: .rounded))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? pastelYellow.opacity(0.18) : NIOThemePaint.fill)
                                    .foregroundStyle(isSelected ? pastelYellow : NIOThemePaint.text.opacity(0.6))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(isSelected ? pastelYellow.opacity(0.6) : NIOThemePaint.stroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if heroPhotoModeRaw == NIOHeroPhotoMode.custom.rawValue {
                        HStack(spacing: 10) {
                            PhotosPicker(selection: $heroPhotoItem, matching: .images) {
                                HStack(spacing: 5) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(NIOHeroPhotoStore.hasCustomPhoto ? "重新导入图片" : "从相册导入")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(LinearGradient(colors: [sakuraPink, lavenderDream], startPoint: .leading, endPoint: .trailing))
                                .clipShape(Capsule())
                            }

                            if NIOHeroPhotoStore.hasCustomPhoto {
                                Button {
                                    NIOHeroPhotoStore.clear()
                                    heroPhotoHint = "已清除导入图片，将回退为渐变背景"
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundStyle(NIOThemePaint.text.opacity(0.6))
                                        .padding(8)
                                        .background(NIOThemePaint.fill)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if let hint = heroPhotoHint {
                            Text(hint)
                                .font(.system(size: 9))
                                .foregroundStyle(mintCyan)
                        } else {
                            Text("导入后保存在本机沙盒，主页 Hero 卡以渐变压暗显示，保证文字可读")
                                .font(.system(size: 9))
                                .foregroundStyle(NIOThemePaint.text.opacity(0.5))
                        }
                    }
                }

                Divider().background(NIOThemePaint.stroke)

                // 特别版切换开关 / 默认
                Button(action: {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    selectedModelSlug = "et5_special"
                    selectedColorSlug = "nature_wonder"
                }) {
                    HStack {
                        Image("NIO_brand")
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                        Text("2026款 ET5 · 自然奇境版 (特别版)")
                            .font(.system(size: 12, weight: selectedModelSlug == "et5_special" ? .bold : .medium))
                            .foregroundStyle(selectedModelSlug == "et5_special" ? pastelYellow : NIOThemePaint.text.opacity(0.85))
                        Spacer()
                        if selectedModelSlug == "et5_special" {
                            Text("当前激活 ✨")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(pastelYellow)
                        }
                    }
                    .padding(10)
                    .background(selectedModelSlug == "et5_special" ? pastelYellow.opacity(0.15) : NIOThemePaint.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedModelSlug == "et5_special" ? pastelYellow.opacity(0.6) : NIOThemePaint.stroke, lineWidth: 1))
                }

                Divider().background(NIOThemePaint.stroke)

                Text("或从蔚来全系官方车系中选择：")
                    .font(.system(size: 11))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.6))

                // 车型选择 Picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(NIOVehicleModelLib.models) { model in
                            let isModelSelected = (selectedModelSlug == model.slug)
                            Button(action: {
                                selectedModelSlug = model.slug
                                if let firstColor = model.colors.first {
                                    selectedColorSlug = firstColor.slug
                                }
                            }) {
                                Text(model.name)
                                    .font(.system(size: 11, weight: isModelSelected ? .bold : .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isModelSelected ? mintCyan.opacity(0.3) : NIOThemePaint.fill)
                                    .foregroundStyle(isModelSelected ? mintCyan : NIOThemePaint.text.opacity(0.8))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(isModelSelected ? mintCyan : NIOThemePaint.stroke, lineWidth: 1))
                            }
                        }
                    }
                }

                // 选中车型的颜色选择
                if let currentModel = NIOVehicleModelLib.findModel(by: selectedModelSlug) {
                    Text("选择【\(currentModel.name)】官方车漆颜色：")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(mintCyan)
                        .padding(.top, 4)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(currentModel.colors) { color in
                            let isColorSelected = (selectedColorSlug == color.slug)
                            Button(action: {
                                selectedColorSlug = color.slug
                            }) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(LinearGradient(colors: [sakuraPink, mintCyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 8, height: 8)
                                    Text(color.name)
                                        .font(.system(size: 10, weight: isColorSelected ? .bold : .regular))
                                        .foregroundStyle(isColorSelected ? .white : NIOThemePaint.text.opacity(0.75))
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(isColorSelected ? sakuraPink.opacity(0.3) : NIOThemePaint.fill)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isColorSelected ? sakuraPink : NIOThemePaint.stroke, lineWidth: 1))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 3.5 🚀 Shadowrocket 直推接收 + 内置 TCP 转发

    /// Shadowrocket 直推凭证接收面板（推荐）
    @ViewBuilder
    private var shadowrocketPushCard: some View {
        cardContainer(title: "🚀 Shadowrocket 直推（推荐）", icon: "bolt.horizontal.fill", accentColor: sakuraPink) {
            VStack(alignment: .leading, spacing: 10) {
                Text("需安装 Shadowrocket（已开启 MITM）。脚本运行后会将 Token / VehicleID 直接推送到本 App，**全程无需手动复制粘贴**。")
                    .font(.system(size: 10))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.7))
                    .lineSpacing(2)

                // 状态行
                // 状态行（即时响应 @Published 变化）
                HStack(spacing: 6) {
                    Circle()
                        .fill(receiver.statusMessage.hasPrefix("✅") ? sakuraPink :
                              receiver.statusMessage.hasPrefix("🟢") ? mintCyan :
                              receiver.statusMessage.hasPrefix("🟡") ? pastelYellow :
                              NIOThemePaint.text.opacity(0.3))
                        .frame(width: 6, height: 6)
                        .animation(.easeInOut(duration: 0.3), value: receiver.statusMessage)
                    Text(receiver.statusMessage)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NIOThemePaint.text.opacity(0.85))
                        .lineLimit(2)
                        .animation(.easeInOut(duration: 0.2), value: receiver.statusMessage)
                }

                // 接收成功横幅（含剪贴板已复制提示）
                if receiver.receiveCount > 0, let t = receiver.lastReceivedAt {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(sakuraPink)
                            Text("已接收 \(receiver.receiveCount) 次 · 最近: \(t.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(sakuraPink)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(mintCyan)
                            Text("凭证 JSON 已自动复制到剪贴板 · 可直接点击「剪贴板读取并识别」")
                                .font(.system(size: 8))
                                .foregroundStyle(mintCyan.opacity(0.9))
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sakuraPink.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(sakuraPink.opacity(0.25), lineWidth: 0.5))
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: receiver.receiveCount)
                }

                HStack(spacing: 8) {
                    // 启动/停止按钮
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        if receiver.isListening { receiver.stopListening() }
                        else { receiver.startListening() }
                    }) {
                        VStack(spacing: 3) {
                            Image(systemName: receiver.isListening ? "stop.fill" : "antenna.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(height: 16)
                            Text(receiver.isListening ? "停止接收" : "1. 开始接收")
                                .font(.system(size: 9, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(height: 12)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(receiver.isListening ? sakuraPink.opacity(0.2) : sakuraPink.opacity(0.15))
                        .foregroundStyle(sakuraPink)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(sakuraPink.opacity(0.4), lineWidth: 0.5))
                    }

                    // 复制模块链接（Shadowrocket 可直接导入）
                    Button(action: {
                        UIPasteboard.general.string = "https://raw.githubusercontent.com/kissggj123/NIO-Dash-iOS/main/scripts/shadowrocket/YumikoToys-NIO.sgmodule"
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                    }) {
                        VStack(spacing: 3) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(height: 16)
                            Text("2. 复制模块链接")
                                .font(.system(size: 9, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(height: 12)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(NIOThemePaint.well)
                        .foregroundStyle(NIOThemePaint.text.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.5))
                    }

                    // 凭证收件箱：查看 / 复制最近推送的每个字段与抓包样本
                    Button(action: { showInboxSheet = true }) {
                        VStack(spacing: 3) {
                            Image(systemName: "tray.full.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(height: 16)
                            Text("3. 凭证收件箱")
                                .font(.system(size: 9, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(height: 12)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(mintCyan.opacity(0.15))
                        .foregroundStyle(mintCyan)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(mintCyan.opacity(0.4), lineWidth: 0.5))
                    }
                }

                // 操作步骤
                VStack(alignment: .leading, spacing: 4) {
                    stepRow("1", "点击「开始接收」启动本地监听（端口 8997）")
                    stepRow("2", "点击「复制模块链接」→ 打开 Shadowrocket → 配置 → 模块 → 新建，粘贴链接导入")
                    stepRow("3", "确认 Shadowrocket 已开启 MITM（需安装证书）")
                    stepRow("4", "打开蔚来 App 下拉刷新爱车页面一次")
                    stepRow("✅", "推送自动回填！字段与抓包样本可在「凭证收件箱」查看复制")
                }
                .font(.system(size: 9))
                .foregroundStyle(NIOThemePaint.text.opacity(0.65))
                .lineSpacing(1.5)
            }
        }
    }

    @ViewBuilder
    private func stepRow(_ num: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(num)
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(sakuraPink)
                .frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inAppVpnSnifferCard: some View {
        cardContainer(title: "🔌 内置 TCP 转发（兜底方案）", icon: "network", accentColor: mintCyan) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("TCP 透传代理 · 无法解密 HTTPS · 建议改用上方 Shadowrocket 方案")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NIOThemePaint.text.opacity(0.7))
                    Spacer()
                    Text(vpnManager.status.rawValue)
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(vpnManager.isVPNActive ? mintCyan.opacity(0.2) : NIOThemePaint.well)
                        .foregroundStyle(vpnManager.isVPNActive ? mintCyan : NIOThemePaint.text.opacity(0.5))
                        .clipShape(Capsule())
                }

                Text("此模式仅转发 TCP 流量，无法解密 TLS 加密内容，因此无法捕获 Authorization Token。推荐使用上方「Shadowrocket 直推」方案替代。")
                    .font(.system(size: 10))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.55))
                    .font(.system(size: 10))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.65))
                    .lineSpacing(2)

                if let summary = vpnManager.lastCapturedSummary {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(mintCyan)
                        Text(summary)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(mintCyan)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(mintCyan.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // 操作按钮行
                HStack(spacing: 8) {
                    // 1. 证书安装按钮
                    Button(action: {
                        certManager.openInstallProfileInSafari()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 10))
                            Text("1. 安装抓包证书")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                        .background(lavenderDream.opacity(0.15))
                        .foregroundStyle(lavenderDream)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(lavenderDream.opacity(0.3), lineWidth: 0.5))
                    }

                    // 2. 启动/停止 VPN 按钮
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        if vpnManager.isVPNActive {
                            vpnManager.stopCaptureVPN()
                        } else {
                            vpnManager.startCaptureVPN()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: vpnManager.isVPNActive ? "stop.fill" : "play.fill")
                                .font(.system(size: 10))
                            Text(vpnManager.isVPNActive ? "停止抓包 VPN" : "2. 启动抓包 VPN")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                        .background(vpnManager.isVPNActive ? sakuraPink.opacity(0.2) : mintCyan.opacity(0.2))
                        .foregroundStyle(vpnManager.isVPNActive ? sakuraPink : mintCyan)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke((vpnManager.isVPNActive ? sakuraPink : mintCyan).opacity(0.4), lineWidth: 0.5))
                    }
                }

                if vpnManager.isVPNActive {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle().fill(mintCyan).frame(width: 6, height: 6)
                            Text("🟢 代理监听中 · 端口 8998")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(mintCyan)
                            Spacer()
                            Button(action: {
                                // 复制本机 Wi-Fi IP 地址
                                let ip = getWiFiIPAddress() ?? "127.0.0.1"
                                UIPasteboard.general.string = "\(ip):8998"
                                let impact = UIImpactFeedbackGenerator(style: .light)
                                impact.impactOccurred()
                            }) {
                                Text("复制代理地址")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(mintCyan.opacity(0.2))
                                    .foregroundStyle(mintCyan)
                                    .clipShape(Capsule())
                            }
                        }

                        // 连接统计（诊断用）
                        let connCount = NIOMitmEngine.shared.connectionCount
                        let sniffCount = NIOMitmEngine.shared.sniffCount
                        HStack(spacing: 12) {
                            Label("\(connCount) 个连接", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(connCount > 0 ? mintCyan : NIOThemePaint.text.opacity(0.4))
                            Label("\(sniffCount) 条凭证", systemImage: "key.fill")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(sniffCount > 0 ? mintCyan : NIOThemePaint.text.opacity(0.4))
                        }

                        // 最近 3 条代理日志
                        let logs = NIOMitmEngine.shared.recentSniffLogs.prefix(3)
                        if !logs.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                                    Text(log)
                                        .font(.system(size: 7.5, design: .monospaced))
                                        .foregroundStyle(NIOThemePaint.text.opacity(0.65))
                                        .lineLimit(1)
                                }
                            }
                        }

                        let localIP = getWiFiIPAddress() ?? "127.0.0.1"
                        Text("💡 将手机 Wi-Fi 代理设为「\(localIP) : 8998」，然后打开蔚来 App 下拉刷新一次")
                            .font(.system(size: 9))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.7))
                            .lineSpacing(1.5)
                    }
                    .padding(8)
                    .background(mintCyan.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(mintCyan.opacity(0.25), lineWidth: 0.5))
                }

                if certManager.certInstalledHint {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(pastelYellow)
                        Text("证书下载后请前往 iOS「设置 -> 已下载描述文件」安装，并在「设置 -> 通用 -> 关于本机 -> 证书信任设置」中开启完全信任。")
                            .font(.system(size: 8))
                            .foregroundStyle(pastelYellow.opacity(0.9))
                    }
                    .padding(6)
                    .background(pastelYellow.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - 4. 智能识别与一键填充

    private var smartParseCard: some View {
        cardContainer(title: "⚡️ 智能识别与一键填充", icon: "wand.and.stars", accentColor: mintCyan) {
            VStack(alignment: .leading, spacing: 10) {
                Text("将抓包 URL、cURL、或嗅探脚本输出的文本直接粘贴到下方：")
                    .font(.system(size: 11))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.7))

                ZStack(alignment: .topLeading) {
                    if smartInput.isEmpty {
                        Text("在此粘贴抓包链接或 cURL 命令…")
                            .font(.system(size: 12))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.25))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }

                    TextEditor(text: $smartInput)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(NIOThemePaint.text)
                        .tint(NIOThemePaint.text)
                        .padding(6)
                        .frame(height: 65)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // 解析过程备注：识别到什么 / 过滤了什么（样本剔除等），可审计
                if !service.lastParseNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(service.lastParseNotes, id: \.self) { note in
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "text.badge.checkmark")
                                    .font(.system(size: 9))
                                    .foregroundStyle(mintCyan)
                                Text(note)
                                    .font(.system(size: 10))
                                    .foregroundStyle(NIOThemePaint.text.opacity(0.75))
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(mintCyan.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 10) {
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        if let clip = UIPasteboard.general.string {
                            smartInput = clip
                            applySmartParse()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard.fill")
                                .font(.system(size: 12))
                            Text("剪贴板读取并识别")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(colors: [mintCyan.opacity(0.8), mintCyan], startPoint: .leading, endPoint: .trailing)
                        )
                        .foregroundStyle(Color.black)
                        .clipShape(Capsule())
                    }

                    Spacer()

                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        applySmartParse()
                    }) {
                        Text("开始解析")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(NIOThemePaint.stroke)
                            .foregroundStyle(NIOThemePaint.text)
                            .clipShape(Capsule())
                    }
                    .disabled(smartInput.isEmpty)
                }

                if showSuccessBanner {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("参数解析成功，已自动填充并启动调度！🌸")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - 3. 车辆 API 必填 (支持 URL 模式 & Widget 动态签名模式)

    private var vehicleApiCard: some View {
        cardContainer(title: "1. 车辆状态 API (双链路协同)", icon: "car.side.fill", accentColor: sakuraPink) {
            VStack(alignment: .leading, spacing: 10) {
                // 双链路协同调度指示横幅
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(sakuraPink)
                        Text("⚡️ 双 API 协同链路架构 (Dual API Engine)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(sakuraPink)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 4) {
                            Text("🟢 链路 1 (Widget 动态签名):")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(mintCyan)
                            Text("负责实时 SOC 电量、续航、充电功率、车锁、定位与温度（动态计算时间戳与签名，永不失效）")
                                .font(.system(size: 9))
                                .foregroundStyle(NIOThemePaint.text.opacity(0.7))
                        }
                        HStack(alignment: .top, spacing: 4) {
                            Text("🔵 链路 2 (RVS 全量遥测):")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(lavenderDream)
                            Text("负责 4 轮胎压/胎温、车机 FOTA、12V 小电瓶、车门车窗全景与车载冰箱（按需拉取并缓存；服务端未返回的字段会明确提示）")
                                .font(.system(size: 9))
                                .foregroundStyle(NIOThemePaint.text.opacity(0.7))
                        }
                    }
                }
                .padding(10)
                .background(sakuraPink.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // 1. Access Token (必填)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Access Token (Bearer)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(sakuraPink)
                        Text("*必填")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.red.opacity(0.8))
                    }

                    SecureField("Bearer 2.0.xxxx... (或直接粘贴完整 cURL)", text: $service.nioVehicleAccessToken)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                        .foregroundStyle(NIOThemePaint.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    // Token 生命周期倒计时（蔚来 access_token 有效期 30 天，无自动续期；签名密钥永久有效）
                    if let days = service.nioTokenDaysRemaining, let expiry = service.nioTokenExpiryDate {
                        HStack(spacing: 4) {
                            Image(systemName: days <= 3 ? "exclamationmark.triangle.fill" : "clock.badge.checkmark")
                                .font(.system(size: 9))
                            Text("Token 剩余约 \(days) 天 · 预计 \(Self.tokenExpiryFormatter.string(from: expiry)) 到期 · 签名密钥永久有效，高频使用可能滑动续期")
                                .font(.system(size: 9))
                            Spacer()
                        }
                        .foregroundStyle(days <= 3 ? Color.red : (days <= 7 ? Color.orange : Color.green.opacity(0.85)))
                    }
                }

                // 2. Vehicle ID (必填/自动填充)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Vehicle ID (车辆 ID)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(mintCyan)
                        Text("推荐")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(mintCyan)
                    }

                    TextField("如 17位VIN 或 9位车辆ID (抓包自动提取)", text: $service.nioVehicleId)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                        .foregroundStyle(NIOThemePaint.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                // 3. API URL (选填 / 抓包直填全量)
                VStack(alignment: .leading, spacing: 4) {
                    Text("API URL（完整 RVS 抓包链接，可多条）")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(lavenderDream)

                    TextField("每行一条完整 /status?... 抓包 URL", text: $service.nioVehicleApiURL, axis: .vertical)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(3...6)
                        .padding(8)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                        .foregroundStyle(NIOThemePaint.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("可分别粘贴含 field=tyre、field=fota 的已签名请求。应用会保留每条 URL 原样，并按需合并不同数据块；不要编辑参数顺序或 sign。")
                        .font(.system(size: 9))
                        .foregroundStyle(NIOThemePaint.text.opacity(0.55))
                }

                // 4. Device ID (选填)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device ID (设备 ID，选填)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(NIOThemePaint.text.opacity(0.7))

                    TextField("抓包中的 device_id (留空将自动生成)", text: $service.nioDeviceId)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                        .foregroundStyle(NIOThemePaint.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                // 5. Sign Secret (选填)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign Secret (动态签名密钥，选填)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(NIOThemePaint.text.opacity(0.7))

                    SecureField("动态签名密钥 (内置 Android 逆向密钥，通常无需修改)", text: $service.nioVehicleSignSecret)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                        .foregroundStyle(NIOThemePaint.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    // 签名算法选择：自定义触发按钮 + Menu 弹层（系统 menu Picker 在 iOS 上会撑满宽度且
                    // label 使用大字号，与配置页 9-11pt 自定义风格错位）
                    HStack(spacing: 8) {
                        Text("签名算法")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.7))
                        Spacer()
                        Menu {
                            Picker(selection: $service.nioVehicleSignAlgo) {
                                ForEach(Self.supportedSignAlgos, id: \.self) { algo in
                                    Text(algoDisplayName(algo)).tag(algo)
                                }
                            } label: { EmptyView() }
                        } label: {
                            HStack(spacing: 5) {
                                Text(service.nioVehicleSignAlgo)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(service.nioVehicleSignAlgo == "md5_full"
                                                     ? Color.green.opacity(0.9) : NIOThemePaint.text)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(NIOThemePaint.text.opacity(0.5))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(NIOThemePaint.well)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                        }
                    }
                }

                Text("💡 说明：使用「智能识别」或「Shadowrocket 直推」时会自动填入以上所有参数，无需手动逐项配置。")
                    .font(.system(size: 9))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.5))
            }
        }
    }

    // MARK: - 4. 扩展服务 (换电 & 签到)

    private var extraServicesCard: some View {
        cardContainer(title: "2. 换电与签到 API (可选)", icon: "bolt.badge.clock.fill", accentColor: lavenderDream) {
            VStack(alignment: .leading, spacing: 12) {
                // 换电
                VStack(alignment: .leading, spacing: 4) {
                    Text("换电记录 API URL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(lavenderDream)

                    TextField("https://app.nio.com/app/api/charge/power_swap/order/list", text: $service.nioChangeApiURL)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                            .foregroundStyle(NIOThemePaint.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("换电 Token (留空则复用车辆 Token)", text: $service.nioChangeAccessToken)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                            .foregroundStyle(NIOThemePaint.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Divider().background(NIOThemePaint.stroke)

                // 签到
                VStack(alignment: .leading, spacing: 4) {
                    Text("每日签到 API URL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(lavenderDream)

                    TextField("https://app.nio.com/app/api/checkin/today", text: $service.nioCheckinApiURL)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                            .foregroundStyle(NIOThemePaint.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("签到 Token (留空则复用车辆 Token)", text: $service.nioCheckinAccessToken)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(NIOThemePaint.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                            .foregroundStyle(NIOThemePaint.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
        }
    }

    // MARK: - 5. 调度与连通性测试

    private var scheduleAndTestCard: some View {
        cardContainer(title: "⏱️ 定时调度与连通测试", icon: "arrow.triangle.2.circlepath", accentColor: pastelYellow) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $service.nioIsAutoPollEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开启后台定时自动拉取")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NIOThemePaint.text)
                        Text("在后台定时更新车况与灵动岛实时数据")
                            .font(.system(size: 9))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.55))
                    }
                }
                .tint(sakuraPink)

                if service.nioIsAutoPollEnabled {
                    HStack {
                        Text("刷新频率")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NIOThemePaint.text)
                        Spacer()
                        Menu {
                            Button("1 分钟") { service.nioVehiclePollIntervalSeconds = 60 }
                            Button("3 分钟") { service.nioVehiclePollIntervalSeconds = 180 }
                            Button("5 分钟 (推荐)") { service.nioVehiclePollIntervalSeconds = 300 }
                            Button("10 分钟") { service.nioVehiclePollIntervalSeconds = 600 }
                        } label: {
                            HStack(spacing: 4) {
                                Text(pollIntervalDisplayName(service.nioVehiclePollIntervalSeconds))
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(mintCyan)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundStyle(mintCyan.opacity(0.7))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(NIOThemePaint.fill)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(8)
                    .background(NIOThemePaint.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Divider().background(NIOThemePaint.stroke)

                // 灵动岛手动开关：被长按强制下岛后在此一键复活上岛；关闭立即结束全部实时活动
                Toggle(isOn: Binding(
                    get: { service.isLiveActivityActive },
                    set: { on in
                        if on {
                            service.raiseLiveActivityFromControl()
                        } else {
                            service.stopLiveActivity()
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("🏝️ 灵动岛实时监控")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NIOThemePaint.text)
                        Text("开启立即重新上岛（长按强制下岛后可在此复活）；关闭将立即结束灵动岛与锁屏实时活动")
                            .font(.system(size: 9))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.55))
                    }
                }
                .tint(sakuraPink)

                Divider().background(NIOThemePaint.stroke)

                // 后台定位保活（自用）：进程不被挂起 → 轮询 Timer 后台照常跑
                Toggle(isOn: $keepAliveEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("📍 后台定位保活与同行监测")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NIOThemePaint.text)
                        Text("低精度定位保持后台刷新；手机接近爱车且快速移动时高频同步车况，识别行驶/等灯/到达与落锁。位置仅本地比对，不存储不上传")
                            .font(.system(size: 9))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.55))
                    }
                }
                .tint(sakuraPink)
                .onChange(of: keepAliveEnabled) { _, on in
                    if on {
                        NIOLocationKeepAlive.shared.requestAndStart()
                    } else {
                        NIOLocationKeepAlive.shared.stop()
                    }
                }

                // 授权状态行 + 主动触发授权 / 跳系统设置
                HStack(spacing: 8) {
                    Image(systemName: keepAliveStatus.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(keepAliveStatus.tint)
                    Text(keepAliveStatus.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NIOThemePaint.text.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer()
                    if keepAliveEnabled, let action = keepAliveStatus.actionLabel {
                        Button {
                            if keepAlive.authorizationStatus == .denied || keepAlive.authorizationStatus == .restricted {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } else {
                                // notDetermined：主动发起系统授权弹窗
                                NIOLocationKeepAlive.shared.requestAndStart()
                            }
                        } label: {
                            Text(action)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(mintCyan)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(NIOThemePaint.fill)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(NIOThemePaint.stroke, lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(NIOThemePaint.fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Divider().background(NIOThemePaint.stroke)

                // 电量里程首选实估
                Toggle(isOn: $preferActualRange) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("🎯 电量里程默认首选实估")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NIOThemePaint.text)
                        Text("主看板与灵动岛/锁屏将默认优先展示实际估算续航，标准续航作为副标展示")
                            .font(.system(size: 9))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.55))
                    }
                }
                .tint(sakuraPink)
                .onChange(of: preferActualRange) { _ in
                    service.updateLiveActivity()
                }

                Button(action: testConnection) {
                    HStack {
                        Spacer()
                        if isTesting {
                            ProgressView()
                                .tint(.black)
                                .padding(.trailing, 6)
                        }
                        Text(isTesting ? "正在拉取车况…" : "⚡️ 立即测试 API 连通性")
                            .font(.system(size: 12, weight: .bold))
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(colors: [pastelYellow, sakuraPink], startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isTesting || !service.isConfigured)

                if let res = testStatusText {
                    HStack(spacing: 6) {
                        Image(systemName: res.contains("成功") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Text(res)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(res.contains("成功") ? Color.green : Color.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(res.contains("成功") ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - 6. 抓取指引

    private var sniffGuideCard: some View {
        cardContainer(title: "📱 手机端与局域网抓取指引", icon: "questionmark.circle.fill", accentColor: .cyan) {
            VStack(alignment: .leading, spacing: 8) {
                guideStepRow(num: "1", text: "在同一局域网运行 Mac 端 `sniff.sh` 抓包脚本或手机抓包工具（Stream / Surge / QX）。")
                guideStepRow(num: "2", text: "打开手机【蔚来 App -> 爱车】下拉刷新车况。")
                guideStepRow(num: "3", text: "筛选域名 `icar.nio.com`，找到包含 `/status` 的请求。")
                guideStepRow(num: "4", text: "复制 cURL 或输出并点击上方【从剪贴板读取并识别】，一秒完成！")

                Button(action: {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    NIOVehicleLib.openNIOApp()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app.fill")
                        Text("一键打开手机蔚来 App 🚀")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(NIOThemePaint.fill)
                    .foregroundStyle(mintCyan)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(mintCyan.opacity(0.3), lineWidth: 0.8))
                }
                .padding(.top, 4)
            }
        }
    }

    private func guideStepRow(num: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle()
                    .fill(NIOThemePaint.stroke)
                    .frame(width: 18, height: 18)
                Text(num)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(mintCyan)
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(NIOThemePaint.text.opacity(0.75))
                .lineSpacing(2)
        }
    }

    // MARK: - 7. 软件关于与诊断入口

    private var aboutAndLogsSection: some View {
        VStack(spacing: 10) {
            Button(action: { showReleaseNotesSheet = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .foregroundStyle(pastelYellow)
                    Text("版本更新日志 (Release Notes)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Spacer()
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.8.0")")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(mintCyan)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NIOThemePaint.text.opacity(0.4))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(NIOThemePaint.fill)
                .foregroundStyle(NIOThemePaint.text)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(pastelYellow.opacity(0.3), lineWidth: 1))
            }

            HStack(spacing: 12) {
                Button(action: { showAboutSheet = true }) {
                    HStack(spacing: 6) {
                        Text("🌸")
                        Text("关于 YumikoToys")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(NIOThemePaint.fill)
                    .foregroundStyle(NIOThemePaint.text)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(sakuraPink.opacity(0.3), lineWidth: 1))
                }

                Button(action: { showLogsSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("运行诊断日志")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(NIOThemePaint.fill)
                    .foregroundStyle(mintCyan)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(mintCyan.opacity(0.3), lineWidth: 1))
                }
            }
        }
    }

    // MARK: - 通用卡片容器

    private func cardContainer<Content: View>(
        title: String,
        icon: String,
        accentColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(NIOThemePaint.text)
                Spacer()
            }

            content()
        }
        .padding(14)
        .background(NIOThemePaint.fill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(NIOThemePaint.fill, lineWidth: 1))
    }

    // MARK: - 逻辑操作

    private func applySmartParse() {
        if service.smartParseInput(smartInput) {
            withAnimation { showSuccessBanner = true }
            // 连点时重置上一轮定时器，避免横幅提前消失或定时器堆叠
            bannerWork.scheduleReplacing(after: 3) {
                withAnimation { showSuccessBanner = false }
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testStatusText = nil
        Task {
            await service.fetchVehicle()
            isTesting = false
            if let err = service.lastError {
                testStatusText = "连通失败：\(err)"
            } else {
                testStatusText = "连通成功！已同步最新车况数据 🌸"
            }
        }
    }

    /// 配置页可选的签名算法（与 NIOVehicleLib.computeWidgetSign 支持的算法一致）
    private static let supportedSignAlgos = ["md5_full", "md5_append", "md5_prepend", "md5_append_key"]

    private static let tokenExpiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private func algoDisplayName(_ algo: String) -> String {
        switch algo {
        case "md5_append": return "MD5 (Query + Secret) [推荐]"
        case "md5_prepend": return "MD5 (Secret + Query)"
        case "md5_append_key": return "MD5 (Query + &key=Secret)"
        case "md5_full": return "MD5 (Method+Path+Query+Secret+Auth) [Android 逆向]"
        default: return algo
        }
    }

    private func pollIntervalDisplayName(_ sec: Int) -> String {
        switch sec {
        case 60: return "1 分钟"
        case 180: return "3 分钟"
        case 300: return "5 分钟 (推荐)"
        case 600: return "10 分钟"
        default: return "\(sec / 60) 分钟"
        }
    }

    /// 后台保活区块的授权状态展示（图标 / 文案 / 颜色 / 可选操作按钮）
    private var keepAliveStatus: (icon: String, text: String, tint: Color, actionLabel: String?) {
        switch keepAlive.authorizationStatus {
        case .notDetermined:
            return ("location.slash", "定位未授权 · 可主动发起授权弹窗", NIOThemePaint.textSoft.opacity(0.7), "发起授权")
        case .denied, .restricted:
            return ("location.slash", "定位被拒绝 · 请到系统设置开启", Color.orange, "前往设置")
        default:
            if keepAlive.isKeepingAlive {
                return ("location.fill", "保活中 · 车况后台准实时刷新", .green, nil)
            }
            if keepAliveEnabled {
                return ("location", "已授权 · 稍后自动启动", mintCyan, nil)
            }
            return ("location", "已授权 · 开关未开启", NIOThemePaint.textSoft.opacity(0.7), nil)
        }
    }

    // MARK: - 背景

    private var animeBackground: some View {
        ZStack {
            themeService.backgroundPrimary()

            RadialGradient(
                colors: [sakuraPink.opacity(0.18), Color.clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 280
            )

            RadialGradient(
                colors: [lavenderDream.opacity(0.16), Color.clear],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: 300
            )
        }
    }
}

// MARK: - 自适应呈现（大屏全屏 / 窄屏 sheet，供设置页子页面统一使用）

private struct AdaptivePresentationModifier<V: View>: ViewModifier {
    let isPresented: Binding<Bool>
    @Environment(\.horizontalSizeClass) private var sizeClass
    let destination: () -> V

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content.fullScreenCover(isPresented: isPresented, content: destination)
        } else {
            content.sheet(isPresented: isPresented, content: destination)
        }
    }
}

extension View {
    /// Duo/iPad 大屏用 fullScreenCover（page sheet 宽度固定 ~640，双列布局触发不了）；iPhone 保持 sheet
    func adaptivePresentation<V: View>(isPresented: Binding<Bool>, @ViewBuilder destination: @escaping () -> V) -> some View {
        modifier(AdaptivePresentationModifier(isPresented: isPresented, destination: destination))
    }
}

// MARK: - 诊断日志视图 (美化版)

struct IOSNIOFetchLogView: View {
    @ObservedObject var service = NIOService.shared
    @ObservedObject private var themeService = AnimeThemeService.shared
    @Environment(\.dismiss) private var dismiss

    private var sakuraPink: Color { themeService.accentColor() }
    private var mintCyan: Color { themeService.glowColor() }

    var body: some View {
        NavigationStack {
            ZStack {
                themeService.backgroundPrimary().ignoresSafeArea()

                if service.fetchLogs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 36))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.3))
                        Text("暂无运行日志")
                            .font(.system(size: 13))
                            .foregroundStyle(NIOThemePaint.text.opacity(0.5))
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(service.fetchLogs) { log in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Label(log.category.uppercased(), systemImage: log.level == "error" ? "xmark.circle.fill" : "checkmark.circle.fill")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(log.level == "error" ? Color.red : mintCyan)
                                        Spacer()
                                        Text(NIOVehicleLib.fmtTime(Int(log.timestamp.timeIntervalSince1970 * 1000)))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(NIOThemePaint.text.opacity(0.4))
                                    }
                                    Text(log.message)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(NIOThemePaint.text.opacity(0.9))

                                    if let url = log.requestURL {
                                        Text(url)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(NIOThemePaint.text.opacity(0.5))
                                            .lineLimit(2)
                                    }

                                    if let preview = log.responsePreview {
                                        Text(preview)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(NIOThemePaint.text.opacity(0.7))
                                            .lineLimit(3)
                                            .padding(6)
                                            .background(NIOThemePaint.well)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                                .padding(10)
                                .background(NIOThemePaint.fill)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(16)
                        // 全屏呈现时限宽居中，日志行不至于拉满超宽屏
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("运行诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(themeService.backgroundPrimary(), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(sakuraPink)
                }
            }
        }
    }
}

// MARK: - Helper: 获取本机 Wi-Fi 局域网 IP

import Darwin

private func getWiFiIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }
    var ptr = ifaddr
    while let ifa = ptr {
        let interface = ifa.pointee
        ptr = ifa.pointee.ifa_next
        // ifa_addr 允许为 NULL（getifaddrs(3) 文档；utun 等虚拟接口常见），
        // 开抓包 VPN 后此函数必然遍历到 utun —— 不判空直接解引用会 EXC_BAD_ACCESS
        guard let addrPtr = interface.ifa_addr else { continue }
        let addrFamily = addrPtr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if name == "en0" {
                var addr = addrPtr.pointee
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(&addr, socklen_t(addrPtr.pointee.sa_len),
                            &hostname, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
            }
        }
    }
    return address
}

// MARK: - 启动动画预览宿主（跳过每日一次闸门，播完自动返回）

struct NIOLaunchPreviewHost: View {
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var finished = false

    var body: some View {
        ZStack {
            IOSNIODashboardView()

            if !finished {
                NIOLaunchSplashView(isFinished: $finished, bypassGate: true)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: finished)
        .onChange(of: finished) { _, done in
            if done {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    dismiss()
                    isPresented = false
                }
            }
        }
    }
}
