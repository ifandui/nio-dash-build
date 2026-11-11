//
//  IOSNIODashboardView.swift
//  wheater
//
//  A native NIO vehicle dashboard. Data semantics mirror NIO-Dash and ha-nio:
//  a single glanceable overview followed by detailed, read-only telemetry.
//

import SwiftUI
import Vision
import CoreImage.CIFilterBuiltins
import MapKit
import CoreLocation

/// 主页车型图片模式：纯渐变 / 内置车型图 / 外部导入
enum NIOHeroPhotoMode: String, CaseIterable, Codable, Identifiable {
    case gradient  // 纯主题渐变（默认）
    case builtin   // 内置车型图 (ET5_CleanPark)
    case custom    // 外部导入图片

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gradient: return "纯渐变"
        case .builtin:  return "内置车型图"
        case .custom:   return "外部导入"
        }
    }
}

/// 外部导入车型图的本地存取 + Vision 原生抠图（VNGenerateForegroundInstanceMaskRequest）
enum NIOHeroPhotoStore {
    static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("nio_hero_photo.jpg")
    }

    /// 抠图结果缓存（透明 PNG）
    static var cutoutURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("nio_hero_cutout.png")
    }

    static func save(data: Data) throws {
        try data.write(to: fileURL, options: .atomic)
    }

    static func load() -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: cutoutURL)
    }

    static var hasCustomPhoto: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Vision 原生抠图

    /// 加载内置车图的抠图结果（透明背景）；无缓存则后台生成
    static func loadBuiltinCutout() -> UIImage? {
        guard let data = try? Data(contentsOf: cutoutURL) else { return nil }
        return UIImage(data: data)
    }

    /// 用 Vision 前景实例分割把图片主体抠成透明背景（iOS 17+）
    static func generateCutout(from image: UIImage) async -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else { return nil }

            let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)

            // 用蒙版把主体从背景中分离（CIBlendWithMask → 透明底）
            let input = CIImage(cgImage: cgImage)
            let mask = CIImage(cvPixelBuffer: maskBuffer)
            let filter = CIFilter.blendWithMask()
            filter.inputImage = input
            filter.backgroundImage = CIImage(color: .clear).cropped(to: input.extent)
            filter.maskImage = mask

            let context = CIContext(options: [.cacheIntermediates: false])
            guard let output = filter.outputImage,
                  let outCG = context.createCGImage(output, from: output.extent) else { return nil }
            return UIImage(cgImage: outCG)
        } catch {
            return nil
        }
    }

    /// 生成（或复用）内置车图抠图；失败时回退原图
    static func builtinCutoutOrOriginal() async -> UIImage? {
        if let cached = loadBuiltinCutout() { return cached }
        let original = UIImage(named: "ET5_CleanPark")
        guard let original else { return nil }
        if let cutout = await generateCutout(from: original),
           let png = cutout.pngData() {
            try? png.write(to: cutoutURL, options: .atomic)
            return cutout
        }
        return original
    }
}

/// iPad 特斯拉式侧边栏分类（NavigationSplitView）
private enum NIOSidebarSection: String, CaseIterable, Identifiable {
    case overview      // 概览
    case vehicle       // 车辆详情
    case modes         // 模式与外设
    case energy        // 能量与能耗
    case tyres         // 轮胎与位置
    case trends        // 趋势与轨迹
    case records       // 维保与记录
    case diagnostics   // 同步诊断

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .vehicle: return "车辆详情"
        case .modes: return "模式与外设"
        case .energy: return "能量与能耗"
        case .tyres: return "轮胎与位置"
        case .trends: return "趋势与轨迹"
        case .records: return "维保与记录"
        case .diagnostics: return "同步诊断"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .vehicle: return "car.fill"
        case .modes: return "switch.2"
        case .energy: return "bolt.batteryblock.fill"
        case .tyres: return "circle.circle"
        case .trends: return "chart.xyaxis.line"
        case .records: return "wrench.and.screwdriver.fill"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// iPad 侧栏行样式：统一图标宽度与文字间距，避免宽图标（如车形）贴字
private struct NIOSidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
                .frame(width: 20)
            configuration.title
        }
    }
}

@MainActor
struct IOSNIODashboardView: View {
    @ObservedObject private var service = NIOService.shared
    // 仅用于订阅主题变化触发重绘；取色统一走 NIOThemePaint
    @ObservedObject private var themeService = AnimeThemeService.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("nio_home_title") private var homeTitle = "兔可可·蔚来"
    @AppStorage("nio_hero_photo_mode") private var heroPhotoModeRaw = NIOHeroPhotoMode.gradient.rawValue
    @AppStorage("nio_vehicle_selected_model") private var selectedModelSlug = "et5_special"
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var selectedSection: DashboardSection = .overview
    @State private var sidebarSection: NIOSidebarSection? = .overview
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    /// 内置车图抠图结果（Vision 前景分割，透明底，异步生成后替换原图）
    @State private var builtinCutout: UIImage?
    /// 外部导入车图缓存（避免 body 每帧磁盘 IO）
    @State private var customPhoto: UIImage?

    private var heroPhotoMode: NIOHeroPhotoMode {
        NIOHeroPhotoMode(rawValue: heroPhotoModeRaw) ?? .gradient
    }

    private var status: NIOVehicleStatus? { service.vehicleData?.data?.status }
    private var soc: NIOSocStatus? { status?.socStatus }
    private var isCharging: Bool {
        NIOVehicleLib.isRealCharging(socStatus: soc, offcarStatus: status?.offcarModeStatus)
    }

    // MARK: - 续航主/副位统一语义
    // 与灵动岛 / 锁屏 / 桌面 Widget（NIOService.buildState）同规则：
    // 开启"实估优先"且有实估 → 主位=实估、副位=CLTC；否则主位=CLTC、副位=实估。
    private var heroRangePreferActual: Bool {
        UserDefaults.standard.bool(forKey: "nio_prefer_actual_range") && (soc?.remainingActualRange ?? 0) > 0
    }
    private var heroMainRange: (value: Double?, label: String) {
        heroRangePreferActual ? (soc?.remainingActualRange, "实估续航") : (soc?.remainingRange, "CLTC 续航")
    }
    private var heroSubRange: (value: Double?, label: String) {
        heroRangePreferActual ? (soc?.remainingRange, "CLTC 续航") : (soc?.remainingActualRange, "实估续航")
    }

    var body: some View {
        if sizeClass == .regular && service.isConfigured {
            // iPad / 大屏：特斯拉式侧边栏 + 车辆主区
            splitLayout
        } else {
            navigationStackLayout
        }
    }

    /// iPhone / compact 单列布局（分段器切换）
    private var navigationStackLayout: some View {
        NavigationStack {
            ZStack {
                NIOAppBackground()
                    .ignoresSafeArea()

                if service.isConfigured {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 18) {
                            vehicleHero
                            sectionPicker
                            selectedContent
                            if let error = service.lastError, !error.isEmpty {
                                NIOAlertCard(message: error, action: { showSettings = true })
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity)
                    }
                    .refreshable { await refresh() }
                    .task(id: heroPhotoModeRaw) {
                        switch heroPhotoMode {
                        case .gradient:
                            break
                        case .builtin:
                            builtinCutout = await NIOHeroPhotoStore.builtinCutoutOrOriginal()
                        case .custom:
                            customPhoto = NIOHeroPhotoStore.load()
                        }
                    }
                } else {
                    NIOEmptyState(onConfigure: { showSettings = true })
                        .padding(24)
                        .frame(maxWidth: 460)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(homeTitle.isEmpty ? "NIO" : homeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { service.refreshAll(force: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(service.isLoadingVehicle)
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                // 设置页可能重新导入/清除了车型图，回来刷新缓存
                if heroPhotoMode == .custom { customPhoto = NIOHeroPhotoStore.load() }
            }) { IOSNIOConfigView() }
            .sheet(isPresented: $showLogs) { IOSNIOFetchLogView() }
        }
    }

    // MARK: - iPad 特斯拉式 Split 布局

    /// 侧边栏（功能分类）+ 详情主区（淡色标题头 + hero 车图 + 上下文卡片）
    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            List(selection: $sidebarSection) {
                ForEach(NIOSidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .symbolRenderingMode(.monochrome) // 统一 sidebar 图标为主题色（car 图标默认 multicolor，破坏配色）
            .labelStyle(NIOSidebarLabelStyle()) // 图标与文字间距（默认太窄，宽车形图标几乎贴字）
            .toolbar(removing: .sidebarToggle) // 移除侧栏右上角系统玻璃钮，折叠走 detailHeader 自定义钮
            .background(
                // 侧栏淡色染底：与详情主题背景呼应
                NIOThemePaint.backgroundSoft.opacity(0.55)
                    .ignoresSafeArea()
            )
            .navigationTitle(homeTitle.isEmpty ? "NIO" : homeTitle)
            .safeAreaInset(edge: .bottom) {
                // 侧栏底部连接状态
                HStack(spacing: 6) {
                    Circle()
                        .fill(service.is403Detected ? .red : (service.isLoadingVehicle ? .orange : .green))
                        .frame(width: 7, height: 7)
                    Text(service.is403Detected ? "凭证失效" : (service.isLoadingVehicle ? "同步中…" : "已连接"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
        } detail: {
            GeometryReader { geo in
                // Duo 展开态 / iPad 宽屏：卡片双列铺满；侧栏展开或折叠窄屏：单列
                let twoColumns = geo.size.width >= 780

                ZStack {
                    NIOAppBackground()
                        .ignoresSafeArea()

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            if service.is403Detected {
                                credentialAlertBanner
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            detailHeader
                            vehicleHero
                            sidebarDetailContent(twoColumns: twoColumns)
                        }
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: service.is403Detected)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                        .frame(maxWidth: twoColumns ? 1040 : 860)
                        .frame(maxWidth: .infinity)
                    }
                    .refreshable { await refresh() }
                    .task(id: heroPhotoModeRaw) {
                        switch heroPhotoMode {
                        case .gradient:
                            break
                        case .builtin:
                            builtinCutout = await NIOHeroPhotoStore.builtinCutoutOrOriginal()
                        case .custom:
                            customPhoto = NIOHeroPhotoStore.load()
                        }
                    }
                }
                // 刷新结果 / 同行事件横幅：顶部悬浮，自动消失
                .overlay(alignment: .top) {
                    if let notice = service.transientNotice {
                        NIOTransientNoticeBanner(notice: notice) {
                            service.transientNotice = nil
                        }
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: service.transientNotice)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .sidebarToggle) // 移除系统玻璃折叠按钮，改用自定义标题头
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { service.refreshAll(force: true, announce: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(service.isLoadingVehicle)
                }
            }
            // 大屏：设置全屏呈现（page sheet 宽度固定 ~640，双列布局永远触发不了）
            .fullScreenCover(isPresented: $showSettings, onDismiss: {
                if heroPhotoMode == .custom { customPhoto = NIOHeroPhotoStore.load() }
            }) { IOSNIOConfigView() }
            .sheet(isPresented: $showLogs) { IOSNIOFetchLogView() }
        }
    }

    /// 详情顶部淡色标题条：分类图标+名称，右侧自定义折叠按钮
    private var detailHeader: some View {
        let section = sidebarSection ?? .overview
        return HStack(spacing: 10) {
            // 自定义折叠按钮（替代系统大玻璃钮）
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    splitVisibility = (splitVisibility == .all) ? .detailOnly : .all
                }
            } label: {
                Image(systemName: splitVisibility == .all ? "sidebar.leading" : "sidebar.squares.leading")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NIOThemePaint.accent)
                    .frame(width: 30, height: 30)
                    .background(NIOThemePaint.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(NIOThemePaint.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Image(systemName: section.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NIOThemePaint.accent)
            Text(section.title)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(NIOThemePaint.text)
            Spacer()
            Text("\((NIOSidebarSection.allCases.firstIndex(of: section) ?? 0) + 1)/\(NIOSidebarSection.allCases.count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(NIOThemePaint.textSoft.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(NIOThemePaint.gradientStart.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(NIOThemePaint.stroke, lineWidth: 1)
        )
    }

    /// 凭证失效横幅：Token 过期（401/403）时在看板顶部醒目提示，点击直达配置页。
    /// 重新拉取成功后由 service.is403Detected 复位自动消失。
    private var credentialAlertBanner: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("蔚来 Token 已失效")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(NIOThemePaint.text)
                    Text("打开蔚来 App 爱车页下拉刷新即可自动更新 · 无需重新登录")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NIOThemePaint.textSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NIOThemePaint.textSoft)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.red.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.red.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 详情主区：按侧栏选择渲染对应卡片组；宽屏拆左右双列
    @ViewBuilder
    private func sidebarDetailContent(twoColumns: Bool) -> some View {
        switch sidebarSection ?? .overview {
        case .overview:
            cardColumns(twoColumns,
                left: { statusCard; energyCard },
                right: { driveCard })
        case .vehicle:
            cardColumns(twoColumns,
                left: { protectionCard },
                right: { cabinCard })
        case .modes:
            cardColumns(twoColumns,
                left: { NIOModesCard(offcar: status?.offcarModeStatus, v2lStatus: soc?.v2lStatus) },
                right: { NIOAccessoriesCard(lvBatt: status?.lvBattStatus, frdg: status?.frdgStatus, heating: status?.heatingStatus, light: status?.lightStatus) })
        case .energy:
            cardColumns(twoColumns,
                left: { energyCard },
                right: { NIOEfficiencyCard(soc: soc, batteryCapacityKwh: service.estimateBatteryCapacityKwh(socStatus: soc)) })
        case .tyres:
            cardColumns(twoColumns,
                left: { tyreCard },
                right: { locationCard })
        case .trends:
            cardColumns(twoColumns,
                left: { NIOHistoryTrendCard(snapshots: service.history, deltas: service.dailyMileageDeltas) },
                right: { NIOTodayTrackCard(path: service.dailyPaths.last) })
        case .records:
            recordsCards
        case .diagnostics:
            diagnosticsCards
        }
    }

    /// 双列包装：宽屏左右两列顶部对齐，窄屏合成单列
    @ViewBuilder
    private func cardColumns<L: View, R: View>(_ enabled: Bool, @ViewBuilder left: () -> L, @ViewBuilder right: () -> R) -> some View {
        if enabled {
            HStack(alignment: .top, spacing: 16) {
                left()
                    .frame(maxWidth: .infinity, alignment: .top)
                right()
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 14) {
                left()
                right()
            }
        }
    }

    private var vehicleHero: some View {
        ZStack(alignment: .bottomLeading) {
            // 车型图层（依设置：内置图 / 外部导入 / 纯渐变）
            heroPhotoLayer

            // 渐变遮罩：纯渐变模式满铺；图片模式垂直渐变（顶部浓保文字、底部透出车形）
            heroOverlay

            Circle()
                .fill(.white.opacity(0.06))
                .frame(width: 260, height: 260)
                .offset(x: 130, y: -95)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Image("NIO_brand")
                                .renderingMode(.template)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                                .foregroundStyle(.white)
                            Text(vehicleName)
                                .font(.title3.weight(.semibold))
                        }
                        HStack(spacing: 5) {
                            Image(systemName: isCharging ? "bolt.fill" : vehicleStateIcon)
                            Text(vehicleStateLabel)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isCharging ? .green : .white.opacity(0.68))
                    }
                    Spacer()
                    if service.isLoadingVehicle {
                        ProgressView().tint(.white)
                    } else {
                        // 连接状态点 + 更新时间（原导航栏徽章迁入，避免 toolbar 挤压截断）
                        HStack(spacing: 5) {
                            Circle()
                                .fill(service.is403Detected ? .red : .green)
                                .frame(width: 6, height: 6)
                            Text(lastUpdatedLabel)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.52))
                        }
                        .lineLimit(1)
                    }
                }

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(soc.map { String(format: "%.0f", $0.soc ?? 0) } ?? "--")
                        .font(.system(size: 68, weight: .thin, design: .rounded))
                    Text("%")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(rangeText(heroMainRange.value))
                            .font(.title3.weight(.semibold))
                        Text(heroMainRange.label)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                GeometryReader { proxy in
                    let fraction = CGFloat(min(1, max(0, (soc?.soc ?? 0) / 100)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        if fraction > 0 {
                            Capsule()
                                .fill(isCharging ? AnyShapeStyle(Color.green) : AnyShapeStyle(NIOThemePaint.accentGradient))
                                .frame(width: max(10, proxy.size.width * fraction))
                                .shadow(color: isCharging ? Color.green.opacity(0.55) : NIOThemePaint.glow.opacity(0.55), radius: 5, y: 0)
                        }
                    }
                }
                .frame(height: 8)

                HStack(spacing: 0) {
                    HeroMetric(title: heroSubRange.label, value: rangeText(heroSubRange.value))
                    HeroMetricDivider()
                    HeroMetric(title: "总里程", value: mileageText)
                    HeroMetricDivider()
                    HeroMetric(title: isCharging ? "充电功率" : "车辆状态", value: isCharging ? powerText : vehicleStateLabel, trailing: true)
                }
            }
            .foregroundStyle(.white)
            .padding(22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
    }

    /// 车型图片层：内置资产 / 外部导入照片 / 无（纯渐变兜底）
    @ViewBuilder
    private var heroPhotoLayer: some View {
        switch heroPhotoMode {
        case .gradient:
            NIOThemePaint.gradientEnd
        case .builtin:
            // Vision 抠图就绪前显示纯渐变（避免黑底原图压在渐变上生硬突兀）
            if let cutout = builtinCutout {
                // 透明车形 + 底部展台辉光：像展厅灯箱一样托住车身
                ZStack {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [NIOThemePaint.accent.opacity(0.42), NIOThemePaint.glow.opacity(0.16), Color.clear],
                                center: .center,
                                startRadius: 8,
                                endRadius: 170
                            )
                        )
                        .frame(width: 330, height: 92)
                        .blur(radius: 14)
                        .offset(y: 6)

                    Image(uiImage: cutout)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .offset(x: -4, y: 10)
                        .shadow(color: NIOThemePaint.accent.opacity(0.35), radius: 18, y: 6)
                }
            } else {
                NIOThemePaint.gradientEnd
            }
        case .custom:
            if let image = customPhoto {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // 未导入图片时兜底为渐变
                NIOThemePaint.accentGradient
            }
        }
    }

    /// 遮罩层：纯渐变模式满铺对角渐变（叠加高光与底部压暗，突出文字层次）；图片模式顶部浓、底部淡，文字清晰且车形透出
    @ViewBuilder
    private var heroOverlay: some View {
        if heroPhotoMode == .gradient {
            ZStack {
                NIOThemePaint.accentGradient
                // 左上高光：给纯渐变一点"打光"的体积感
                RadialGradient(
                    colors: [.white.opacity(0.20), .clear],
                    center: UnitPoint(x: 0.12, y: -0.05),
                    startRadius: 10,
                    endRadius: 400
                )
                // 底部压暗：保证 hero 指标行的可读性
                LinearGradient(
                    colors: [.black.opacity(0.16), .clear],
                    startPoint: .bottom,
                    endPoint: .center
                )
            }
        } else {
            LinearGradient(
                stops: [
                    .init(color: NIOThemePaint.gradientStart.opacity(0.9), location: 0),
                    .init(color: NIOThemePaint.gradientStart.opacity(0.4), location: 0.48),
                    .init(color: NIOThemePaint.gradientEnd.opacity(0.34), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var sectionPicker: some View {
        Picker("看板", selection: $selectedSection) {
            ForEach(DashboardSection.allCases) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .overview: overview
        case .vehicle: vehicleDetail
        case .insights: insights
        }
    }

    // MARK: - 可复用卡片（iPhone 分段与 iPad 侧栏共用）

    private var statusCard: some View {
        NIOSectionCard(title: "当前状态", subtitle: "来自车辆实时遥测") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatusTile(icon: "lock.fill", title: "车锁", value: isLocked ? "已上锁" : "未上锁", tint: isLocked ? .green : .orange)
                StatusTile(icon: "door.left.hand.open", title: "车门", value: allDoorsClosed ? "已关好" : "请检查", tint: allDoorsClosed ? .green : .orange)
                StatusTile(icon: "car.rear.fill", title: "尾门", value: tailgateClosed ? "已关闭" : "未关闭", tint: tailgateClosed ? .green : .orange)
                StatusTile(icon: "window.vertical.open", title: "车窗", value: windowsClosed ? "已关闭" : "有开启", tint: windowsClosed ? .green : .orange)
                StatusTile(icon: "thermometer.medium", title: "座舱温度", value: temperatureText, tint: .cyan)
            }
        }
    }

    private var energyCard: some View {
        NIOSectionCard(title: "能量", subtitle: isCharging ? "正在充电" : "电池与续航") {
            VStack(spacing: 0) {
                KeyValueRow(label: "充电状态", value: NIOVehicleLib.smartChargeStateDescription(socStatus: soc, offcarStatus: status?.offcarModeStatus))
                Divider()
                KeyValueRow(label: "目标电量", value: soc?.targetSocPercentage.map { String(format: "%.0f%%", $0) } ?? "--")
                Divider()
                // lock_soc 与 max_soc 同为服务端常驻默认 90（非真实设定），仅与默认值不同时展示；
                // 有用户设定限充（target_soc_percentage）时优先展示它
                KeyValueRow(label: "电池锁定下限", value: lockSocDisplayText)
            }
        }
    }

    /// 电池锁定下限展示：lock_soc 服务端常驻 90 时视为无有效值显示 "--"
    private var lockSocDisplayText: String {
        if let t = soc?.targetSocPercentage, t > 1, t <= 100 { return String(format: "%.0f%%", t) }
        if let l = soc?.lockSoc, l > 1, l <= 100, abs(l - 90) > 0.01 { return String(format: "%.0f%%", l) }
        return "--"
    }

    private var driveCard: some View {
        NIOSectionCard(title: "行驶", subtitle: "来自 RVS exterior status") {
            VStack(spacing: 0) {
                KeyValueRow(label: "当前车速", value: status?.exteriorStatus?.speed.map { String(format: "%.0f km/h", $0) } ?? "--")
                Divider()
                KeyValueRow(label: "行驶状态", value: vehicleStateLabel)
                Divider()
                KeyValueRow(label: "数据采样", value: sampleTimeLabel)
            }
        }
    }

    private var vehicleProtectionCards: some View {
        VStack(spacing: 14) {
            protectionCard
            cabinCard
        }
    }

    private var protectionCard: some View {
        NIOSectionCard(title: "车辆防护", subtitle: "门、窗与连接状态") {
                let entries = NIOVehicleLib.parseAvailableDoors(doorStatus: status?.doorStatus, windowStatus: status?.windowStatus, isCharging: isCharging)
                VStack(spacing: 0) {
                    ForEach(entries) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .frame(width: 22)
                                .foregroundStyle(item.isClosed ? .green : .orange)
                            Text(item.title)
                            Spacer()
                            Text(item.isClosed ? "正常" : "注意")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(item.isClosed ? .green : .orange)
                        }
                        .padding(.vertical, 10)
                        if item.id != entries.last?.id { Divider() }
                    }
                }
            }
    }

    private var cabinCard: some View {
        NIOSectionCard(title: "座舱与系统", subtitle: "空调、车机与低压电瓶") {
            VStack(spacing: 0) {
                KeyValueRow(label: "空调", value: status?.hvacStatus?.airConditionerOn == true ? "已开启" : "已关闭")
                Divider()
                KeyValueRow(label: "特殊模式", value: specialModesText)
                Divider()
                KeyValueRow(label: "车外温度", value: degreeText(status?.hvacStatus?.outsideTemperature))
                Divider()
                KeyValueRow(label: "车机版本", value: fotaDisplay)
                Divider()
                KeyValueRow(label: "云端连接", value: status?.connectionStatus?.connected == true ? "在线" : "状态未知")
            }
        }
    }

    private var recordsCards: some View {
        VStack(spacing: 14) {
            NIOSectionCard(title: "行驶记录", subtitle: "基于本地历史采样") {
                HStack {
                    InsightMetric(value: "\(service.history.count)", label: "历史采样")
                    Divider().frame(height: 38)
                    InsightMetric(value: "\(service.dailyPaths.count)", label: "行驶日期")
                    Divider().frame(height: 38)
                    InsightMetric(value: "\(service.dailyMileageDeltas.count)", label: "里程记录")
                }
            }
            NIOSectionCard(title: "服务与换电", subtitle: "订单同步数据") {
                HStack {
                    InsightMetric(value: "\(service.serviceSummary?.swapCompleted ?? 0)", label: "已完成换电")
                    Divider().frame(height: 38)
                    InsightMetric(value: "\(service.serviceSummary?.total ?? 0)", label: "服务订单")
                    Divider().frame(height: 38)
                    InsightMetric(value: checkinValue, label: "连续签到")
                }
            }

            NIOSwapOverviewCard(summary: service.serviceSummary)
            NIOTopStationsCard(stations: service.serviceSummary?.topSwapStations ?? [])
            NIOOrderListCard(orders: service.serviceSummary?.orders ?? service.recentOrders)

            NIOMaintenanceCard(mileageKm: status?.exteriorStatus?.mileage, orders: service.recentOrders)
        }
    }

    private var diagnosticsCards: some View {
        VStack(spacing: 14) {
            if let error = service.lastError, !error.isEmpty {
                NIOAlertCard(message: error, action: { showSettings = true })
            }
            if telemetryWarning != nil {
                NIOSectionCard(title: "遥测诊断", subtitle: "RVS 状态请求字段检查") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(telemetryWarning!, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("请在 NIO App 的爱车页下拉刷新后，重新抓取完整的 /rvs/vehicle/.../status 请求；不要修改 URL 的 field、参数顺序或 sign。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("打开配置") { showSettings = true }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            NIOSectionCard(title: "同步诊断", subtitle: "最近请求与响应记录") {
                Button { showLogs = true } label: {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("查看同步日志")
                        Spacer()
                        Text("\(service.fetchLogs.count) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private var overview: some View {
        VStack(spacing: 14) {
            NIOVehicleControlPanel(service: service)
            NIOBluetoothKeysCard(service: service)
            statusCard
            energyCard
            NIOEfficiencyCard(soc: soc, batteryCapacityKwh: service.estimateBatteryCapacityKwh(socStatus: soc))
            NIOModesCard(offcar: status?.offcarModeStatus, v2lStatus: soc?.v2lStatus)
            NIOAccessoriesCard(
                lvBatt: status?.lvBattStatus,
                frdg: status?.frdgStatus,
                heating: status?.heatingStatus,
                light: status?.lightStatus
            )
            tyreCard
            locationCard
        }
    }

    private var tyreCard: some View {
        // Do not use NIOVehicleLib.extractTyreInfo(from:) here: its deliberate
        // 2.5 bar preview fallback is useful for a widget layout, but would make
        // a missing RVS `tyre` block look like live vehicle data in the app.
        let tyres = NIOVehicleLib.extractTyreInfo(status?.tyreStatus)
        return NIOSectionCard(title: "轮胎", subtitle: "胎压与胎温") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                TyreTile(position: "左前", item: tyres.fl)
                TyreTile(position: "右前", item: tyres.fr)
                TyreTile(position: "左后", item: tyres.rl)
                TyreTile(position: "右后", item: tyres.rr)
            }
        }
    }

    @ViewBuilder
    private var locationCard: some View {
        if let position = status?.positionStatus,
           let latitude = position.latitude,
           let longitude = position.longitude,
           NIOVehicleLib.isValidGPS(lat: latitude, lng: longitude) {
            NIOParkingLocationCard(latitude: latitude, longitude: longitude)
        }
    }

    private var vehicleDetail: some View {
        VStack(spacing: 14) {
            vehicleProtectionCards
            driveCard
        }
    }

    private var insights: some View {
        VStack(spacing: 14) {
            NIOHistoryTrendCard(snapshots: service.history, deltas: service.dailyMileageDeltas)

            NIOTodayTrackCard(path: service.dailyPaths.last)

            recordsCards
            diagnosticsCards
        }
    }

    private func refresh() async {
        await service.fetchVehicle(force: true, announce: true)
        await service.fetchChange(force: true)
        await service.fetchCheckin(force: true)
        service.updateLiveActivity()
    }

    private var vehicleName: String {
        // 跟随设置页选择的车型名称；特别版单独映射，其余走官方车型库
        if selectedModelSlug == "et5_special" { return "ET5 · 自然奇境版" }
        if let model = NIOVehicleModelLib.findModel(by: selectedModelSlug) {
            return model.name
        }
        return status?.vehicleId.map { "NIO \($0.suffix(6))" } ?? "我的 NIO"
    }
    private var isLocked: Bool { (status?.doorStatus?["vehicle_lock_status"]?.intValue ?? 1) == 1 }
    private var allDoorsClosed: Bool { NIOVehicleLib.parseAvailableDoors(doorStatus: status?.doorStatus, windowStatus: nil, isCharging: isCharging).filter { $0.id != "vehicle_lock" }.allSatisfy(\.isClosed) }
    private var windowsClosed: Bool { NIOVehicleLib.parseAvailableDoors(doorStatus: nil, windowStatus: status?.windowStatus).first { $0.id == "windows" }?.isClosed ?? true }
    /// 尾门独立判定（widget/info door_status.tailgate_ajar_status：1=关 0=开）
    private var tailgateClosed: Bool { NIOVehicleLib.parseAvailableDoors(doorStatus: status?.doorStatus, windowStatus: nil).first { $0.id == "trunk" }?.isClosed ?? true }
    private var mileageText: String { status?.exteriorStatus?.mileage.map { String(format: "%.0f km", $0) } ?? "--" }
    private var powerText: String { soc?.chargingPower.map { String(format: "%.1f kW", $0 / ($0 > 100 ? 1000 : 1)) } ?? "--" }
    private var temperatureText: String { degreeText(status?.hvacStatus?.temperature) }
    /// 特殊模式汇总（超强干燥 / 极速除霜 / 座舱过热保护 / 守卫 / 宠物 / 露营 / 离车不下电 / 对外放电）
    private var specialModesText: String {
        let hvac = status?.hvacStatus
        var modes: [String] = []
        if hvac?.cbnHiTDrySts == 1 { modes.append("♨️ 超强干燥") }
        if hvac?.ccuMaxDefrstSts == 1 { modes.append("❄️ 极速除霜") }
        if hvac?.cbnOvrHtActSts == 1 { modes.append("🌡️ 过热保护") }
        if NIOVehicleLib.defenderModeActive(status?.offcarModeStatus ?? [:]).isActive { modes.append("🛡️ 守卫") }
        if NIOVehicleLib.modeActive(status?.offcarModeStatus?["pet_mode_status"] ?? status?.offcarModeStatus?["pet_mode"]) { modes.append("🐾 宠物模式") }
        if NIOVehicleLib.modeActive(status?.offcarModeStatus?["camping_mode_status"] ?? status?.offcarModeStatus?["camping_mode"]) { modes.append("⛺️ 露营模式") }
        if NIOVehicleLib.modeActive(status?.offcarModeStatus?["power_hold_mode_status"] ?? status?.offcarModeStatus?["power_hold_mode"]) { modes.append("🔋 离车不下电") }
        if soc?.v2lStatus == 1 { modes.append("🔌 对外放电") }
        return modes.isEmpty ? "无" : modes.joined(separator: " · ")
    }
    private var checkinValue: String { service.checkinData.map { "\($0.continuousDays) 天" } ?? "--" }
    private var fotaDisplay: String {
        let fota = status?.fotaStatus
        let raw = [fota?.currentVersion, fota?.lastVersion, fota?.currentPartNo]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let raw else { return "未返回" }
        return NIOVehicleLib.parseFotaInfo(version: raw).fullDisplay
    }
    private var telemetryWarning: String? {
        let tyreMissing = !NIOVehicleLib.extractTyreInfo(status?.tyreStatus).hasData
        let fotaMissing = status?.fotaStatus?.currentVersion?.isEmpty != false
            && status?.fotaStatus?.lastVersion?.isEmpty != false
        switch (tyreMissing, fotaMissing) {
        case (true, true): return "当前请求未返回胎压和车机版本"
        case (true, false): return "当前请求未返回胎压数据"
        case (false, true): return "当前请求未返回车机版本"
        case (false, false): return nil
        }
    }
    private var sampleTimeLabel: String { dateLabel(status?.socStatus?.sampleTime ?? status?.exteriorStatus?.sampleTime) }
    private var lastUpdatedLabel: String { service.lastVehicleFetch.map { $0.formatted(date: .omitted, time: .shortened) } ?? "未同步" }
    private var vehicleStateIcon: String { status?.exteriorStatus?.vehicleState == 1 ? "steeringwheel" : "parkingsign" }
    private var vehicleStateLabel: String { status?.exteriorStatus?.vehicleState == 1 ? "行驶中" : "已驻车" }
    private func rangeText(_ value: Double?) -> String { value.map { String(format: "%.0f km", $0) } ?? "--" }
    private func degreeText(_ value: Double?) -> String { value.map { String(format: "%.0f℃", $0) } ?? "--" }
    private func dateLabel(_ timestamp: Int?) -> String {
        guard let timestamp, timestamp > 0 else { return "--" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp))
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, vehicle, insights
    var id: String { rawValue }
    var title: String { switch self { case .overview: "概览"; case .vehicle: "车辆"; case .insights: "记录" } }
}

private struct NIOAppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [NIOThemePaint.background, NIOThemePaint.backgroundSoft],
                startPoint: .top,
                endPoint: .bottom
            )
            // 顶部主题辉光：给纯渐变背景一点纵深
            RadialGradient(
                colors: [NIOThemePaint.glow.opacity(0.16), .clear],
                center: UnitPoint(x: 0.5, y: -0.12),
                startRadius: 20,
                endRadius: 520
            )
        }
    }
}

/// 刷新结果 / 同行事件横幅：顶部悬浮胶囊，3.5 秒后自动消失（新横幅会重置计时），点击可提前关闭
struct NIOTransientNoticeBanner: View {
    let notice: NIOTransientNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.kind.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(notice.message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NIOThemePaint.text)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(NIOThemePaint.fill)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
        .overlay(Capsule(style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 20)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { onDismiss() } // 点击任意位置提前关闭
        .task(id: notice.id) {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            onDismiss()
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .success: return .green
        case .neutral: return .secondary
        case .warn: return .orange
        case .info: return NIOThemePaint.accent
        }
    }
}

private struct NIOEmptyState: View {
    let onConfigure: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "car.2.fill")
                .font(.system(size: 44))
                .foregroundStyle(NIOThemePaint.accentGradient)
            Text("连接你的 NIO").font(.title2.weight(.semibold))
            Text("粘贴从 NIO App 获取的车辆状态 URL 和 Access Token，即可在这里查看实时车况。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("开始配置", action: onConfigure)
                .buttonStyle(.borderedProminent)
                .tint(NIOThemePaint.accent)
        }
    }
}

private struct NIOAlertCard: View {
    let message: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(message).lineLimit(2); Spacer(); Image(systemName: "chevron.right") }
                .font(.subheadline).foregroundStyle(.orange)
                .padding(14)
                .background(.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.orange.opacity(0.30), lineWidth: 1)
                )
        }
    }
}

/// 看板卡片壳统一走 NIODashCardShell（含主题标题条 / 描边 / 阴影），此别名保留原调用点
private struct NIOSectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        NIODashCardShell(title: title, subtitle: subtitle) { content }
    }
}

// MARK: - 停车位置卡（内嵌苹果地图 + 逆地理编码 + 外部地图跳转）

private struct NIOParkingLocationCard: View {
    let latitude: Double
    let longitude: Double

    @State private var placemarkText: String?
    @State private var isLoadingPlacemark = false
    // 相机位置绑定态：initialPosition 只在首次渲染生效，车辆位置更新后地图不会跟随；
    // 改为绑定 position 并在坐标变化时重设，实现停车纠偏/位置更新后地图实时跟随
    @State private var cameraPosition: MapCameraPosition

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        )))
    }

    /// 车辆位置刷新（停车纠偏/重新定位）时平移相机到新坐标
    private func followUpdatedPosition() {
        cameraPosition = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        ))
    }

    /// 蔚来 API 返回的坐标经测试为 WGS-84（与轨迹卡一致，直接使用不做 GCJ-02 转换）
    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var appleMapsURL: URL? {
        URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=车辆停放位置")
    }

    private var amapURL: URL? {
        // dev=1 表示传入的是 WGS-84 坐标，高德内部自动转 GCJ-02
        URL(string: "iosamap://viewMap?sourceApplication=YumikoToysRR&poiname=车辆停放位置&lat=\(latitude)&lon=\(longitude)&dev=1")
    }

    private var baiduMapsURL: URL? {
        // coord_type=wgs84 声明坐标类型，百度内部自动转 BD-09
        URL(string: "baidumap://map/marker?location=\(latitude),\(longitude)&coord_type=wgs84&title=车辆停放位置&content=停车位置&src=YumikoToysRR")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("车辆位置")
                        .font(.headline)
                    if let placemarkText {
                        Text(placemarkText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("定位数据可能存在延迟")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isLoadingPlacemark {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button {
                        reverseGeocode()
                    } label: {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 内嵌苹果地图（position 绑定，坐标更新时相机自动跟随）
            Map(position: $cameraPosition) {
                Marker("车辆停放位置", coordinate: coordinate)
                    .tint(.red)
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .allowsHitTesting(false)
            .onChange(of: latitude) { followUpdatedPosition() }
            .onChange(of: longitude) { followUpdatedPosition() }

            // 停放描述
            if let placemarkText {
                Label(placemarkText, systemImage: "pin.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            // 外部地图跳转按钮
            HStack(spacing: 10) {
                if let appleMapsURL {
                    Link(destination: appleMapsURL) {
                        mapButton(icon: "map.fill", label: "苹果地图", tint: .blue)
                    }
                }
                if let amapURL, UIApplication.shared.canOpenURL(amapURL) {
                    Link(destination: amapURL) {
                        mapButton(icon: "location.fill", label: "高德地图", tint: .green)
                    }
                }
                if let baiduMapsURL, UIApplication.shared.canOpenURL(baiduMapsURL) {
                    Link(destination: baiduMapsURL) {
                        mapButton(icon: "signpost.right.fill", label: "百度地图", tint: .orange)
                    }
                }
            }

            // 坐标
            Text(String(format: "%.5f, %.5f", latitude, longitude))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(NIOThemePaint.fill)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { reverseGeocode() }
    }

    private func mapButton(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func reverseGeocode() {
        guard !isLoadingPlacemark else { return }
        isLoadingPlacemark = true
        Task { @MainActor in
            defer { isLoadingPlacemark = false }
            do {
                // iOS 26 MapKit 逆地理（CLGeocoder 已弃用）；mapItems 回调标注为 UI Actor，天然主线程
                guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else {
                    placemarkText = nil
                    return
                }
                let items = try await request.mapItems
                guard let item = items.first else {
                    placemarkText = nil
                    return
                }
                placemarkText = Self.formatAddress(from: item)
            } catch {
                placemarkText = nil
            }
        }
    }

    /// iOS 26 逆地理已无街道级分字段（placemark 一并弃用）：
    /// 短地址 → 完整地址 → 城市名 逐级兜底拼接"停放于…附近"
    private static func formatAddress(from item: MKMapItem) -> String {
        if let short = item.address?.shortAddress, !short.isEmpty {
            return "停放于\(short)附近"
        }
        if let full = item.address?.fullAddress, !full.isEmpty {
            return "停放于\(full)附近"
        }
        if let city = item.addressRepresentations?.cityName, !city.isEmpty {
            return "停放于\(city)附近"
        }
        return "停放位置"
    }
}

private struct HeroMetric: View {
    let title: String; let value: String; var trailing = false
    var body: some View { VStack(alignment: trailing ? .trailing : .leading, spacing: 2) { Text(value).font(.subheadline.weight(.semibold)); Text(title).font(.caption2).foregroundStyle(.white.opacity(0.52)) }.frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading) }
}

/// hero 指标行之间的细分隔线（白色微透明，融入渐变底）
private struct HeroMetricDivider: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 10)
    }
}

private struct StatusTile: View {
    let icon: String; let title: String; let value: String; let tint: Color
    var body: some View {
        HStack(spacing: 10) {
            // 图标底座：着色圆角小块，比裸图标更有层次
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct KeyValueRow: View {
    let label: String; let value: String
    var body: some View { HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing).font(.subheadline.weight(.medium)) }.padding(.vertical, 10) }
}

private struct TyreTile: View {
    let position: String; let item: NIOVehicleLib.TyreWheelInfo
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(position).font(.caption).foregroundStyle(.secondary); Text(item.press.map { String(format: "%.1f bar", $0) } ?? "--").font(.subheadline.weight(.semibold)); Text(item.temp.map { "\($0)℃" } ?? "温度 --").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NIOThemePaint.stroke, lineWidth: 1)) }
}

private struct InsightMetric: View {
    let value: String; let label: String
    var body: some View { VStack(spacing: 3) { Text(value).font(.title3.weight(.semibold)); Text(label).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) }
}
import SwiftUI

// MARK: - 蓝牙钥匙管理卡片（virtual_key list_by_vehicle_v3 逆向接口）

/// 蓝牙钥匙列表：展示钥匙类型/名称/状态/有效期；字段结构未完全逆向时回退原始 JSON 预览。
/// 需要用户级 access_token（车级 token 会返回 no access found）。
struct NIOBluetoothKeysCard: View {
    @ObservedObject var service: NIOService

    var body: some View {
        NIOSectionCard(title: "蓝牙钥匙", subtitle: "virtual_key list_by_vehicle_v3 · 需用户级 Token") {
            VStack(spacing: 0) {
                if service.isLoadingVirtualKeys {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在拉取钥匙列表…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                } else if let err = service.virtualKeysError {
                    VStack(spacing: 6) {
                        Text("⚠️ \(err)").font(.caption).foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        Button("重试") { Task { await service.fetchVirtualKeys() } }
                            .font(.caption)
                        Text("车控/钥匙接口需要主 App 会话的用户级 access_token；小组件抓包的车级 token 无此权限")
                            .font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                } else if service.virtualKeys.isEmpty {
                    Button {
                        Task { await service.fetchVirtualKeys() }
                    } label: {
                        Text("暂无数据，点击重新拉取").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                } else {
                    ForEach(service.virtualKeys.indices, id: \.self) { idx in
                        let key = service.virtualKeys[idx]
                        keyRow(key)
                        if idx < service.virtualKeys.count - 1 { Divider() }
                    }
                }
            }
        }
        .task { if service.virtualKeys.isEmpty && service.virtualKeysError == nil { await service.fetchVirtualKeys() } }
    }

    private func keyRow(_ key: [String: Any]) -> some View {
        let name = (key["key_name"] ?? key["name"] ?? key["nick_name"] ?? key["user_name"]) as? String
        let type = (key["key_type"] ?? key["type"]) as? String
        let status = (key["status"] ?? key["key_status"] ?? key["state"]) as? String
        let expire = (key["expire_time"] ?? key["expired_time"] ?? key["valid_to"]) as? String
            ?? ((key["expire_time"] as? Double).map { NIOFormatters.dateTime.string(from: Date(timeIntervalSince1970: $0)) })
        let known = (name != nil) || (type != nil) || (status != nil)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill").foregroundStyle(.pink)
                Text(name ?? "钥匙 #\(key["key_id"] as? String ?? key["id"] as? String ?? "?")")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let status {
                    Text(status).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.pink.opacity(0.12)))
                }
            }
            if let type { Text("类型：\(type)").font(.caption).foregroundStyle(.secondary) }
            if let expire { Text("有效期至：\(expire)").font(.caption).foregroundStyle(.secondary) }
            if !known {
                // 结构未识别 → 原始 JSON 兜底展示
                if let data = try? JSONSerialization.data(withJSONObject: key, options: [.sortedKeys]),
                   let s = String(data: data, encoding: .utf8) {
                    Text(String(s.prefix(220)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(4)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 车控面板（REST 异步命令通道逆向实现）
//
// 8 个常用指令网格；点击 → 二次确认 Alert（敏感指令标红警示）→ 发送 →
// 服务端要求服务密码时自动弹出 PIN 输入框（RSA 加密提交 /api/1/poseidon/verify_pin）→ 重发指令。
// 进度与结果通过 NIOService.publishTransientNotice 横幅展示。
struct NIOVehicleControlPanel: View {
    @ObservedObject var service: NIOService

    @State private var pendingCommand: NIOVehicleLib.CommandEntry?
    @State private var showConfirm = false
    @State private var showPinAlert = false
    @State private var pinInput = ""
    @State private var isSending = false

    var body: some View {
        NIOSectionCard(title: "车控", subtitle: "逆向 REST 命令通道 · 谨慎使用") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(NIOVehicleLib.vehicleCommandEntries, id: \.function) { cmd in
                    Button {
                        pendingCommand = cmd
                        showConfirm = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: cmd.icon)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(height: 20)
                            // 单行缩放：避免"发动机禁用"等长标题换行导致同行按钮高度不一
                            Text(cmd.title)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(height: 13)
                        }
                        .foregroundStyle(isSending ? Color.secondary : (cmd.sensitive ? Color.orange : Color.primary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NIOThemePaint.stroke, lineWidth: 1))
                    }
                    .disabled(isSending)
                }
            }
            Text("解锁 / 开窗 / 尾门等敏感指令需要服务密码；寻车与大灯会实际影响车辆，请在车旁使用")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // WebSocket 实时流（实验）：哨兵/召车/车控事件推送通道
            Divider()
            HStack(spacing: 10) {
                Image(systemName: service.isCommandStreamConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowave.left.and.right.slash")
                    .foregroundStyle(service.isCommandStreamConnected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("命令实时流（实验）").font(.system(size: 12, weight: .bold))
                    Text(service.isCommandStreamConnected
                         ? "已连接 · 收到 \(service.commandStreamLog.count) 帧事件"
                         : "wss 哨兵/召车事件通道，用于验证握手参数")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(service.isCommandStreamConnected ? "断开" : "连接") {
                    if service.isCommandStreamConnected {
                        service.disconnectCommandStream()
                    } else {
                        service.connectCommandStream()
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.bordered)
            }
            if !service.commandStreamLog.isEmpty {
                Text(service.commandStreamLog.suffix(3).joined(separator: "\n"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
        }
        .confirmationDialog(
            "确认执行「\(pendingCommand?.title ?? "")」？",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("执行", role: pendingCommand?.sensitive == true ? .destructive : nil) {
                Task { await execute(pendingCommand) }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(pendingCommand?.sensitive == true
                 ? "该指令会实际改变车辆状态，请确认车辆当前安全。"
                 : "指令将通过蔚来官方命令通道发送。")
        }
        .alert("服务密码", isPresented: $showPinAlert) {
            SecureField("服务密码", text: $pinInput)
            Button("验证并执行") { Task { await submitPin() } }
            Button("取消", role: .cancel) { pinInput = "" }
        } message: {
            Text("服务端要求验证服务密码（PIN），输入后将加密提交验证并重发指令")
        }
    }

    @MainActor
    private func execute(_ cmd: NIOVehicleLib.CommandEntry?) async {
        guard let cmd else { return }
        isSending = true
        defer { isSending = false }
        let result = await service.sendVehicleCommand(function: cmd.function, title: cmd.title)
        handle(result: result, cmd: cmd)
    }

    @MainActor
    private func submitPin() async {
        let pin = pinInput
        let cmd = pendingCommand
        pinInput = ""
        guard let cmd else { return }
        isSending = true
        defer { isSending = false }
        let result = await service.verifyPinAndRetry(pin, function: cmd.function, title: cmd.title)
        handle(result: result, cmd: cmd)
    }

    @MainActor
    private func handle(result: NIOService.VehicleCommandResult, cmd: NIOVehicleLib.CommandEntry) {
        switch result {
        case .success(let msg):
            service.publishTransientNotice(.success, "✅ \(msg)")
        case .needPin:
            service.publishTransientNotice(.info, "🔒 「\(cmd.title)」需要服务密码验证")
            showPinAlert = true
        case .failure(let msg):
            service.publishTransientNotice(.warn, "⚠️ \(msg)")
        }
    }
}
