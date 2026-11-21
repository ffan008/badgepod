import SwiftUI

/// 吧唧录音库的颜色：暖灰的底，玫瑰红是强调色（选中、要点、播放、录音），琥珀色只用在场景小图标和设备上。不用蓝和紫。
nonisolated enum Theme {
    /// 圆角：跟 Chrome 的尺度走，别太圆（2026-11-16 用户要求）。新写的界面只用这几档；
    /// 纯圆形按钮（Circle）、真正的胶囊（Capsule、开关）不在此列。
    enum Radius {
        /// 大面板、卡片底板、弹窗里的分组
        static let panel: CGFloat = 10
        /// 列表里的一张张卡片、缩略图、按钮、输入框
        static let card: CGFloat = 8
        /// 小标签、筛选胶囊、图标底块
        static let chip: CGFloat = 6
    }

    /// 强调色：玫瑰红。浅色 rose-500，深色 rose-400。
    static let accent = dynamic(light: (0.957, 0.247, 0.369), dark: (0.984, 0.443, 0.522))
    /// 场景小图标、设备卡用的暖琥珀。
    static let amber = dynamic(light: (0.851, 0.467, 0.024), dark: (0.984, 0.749, 0.141))
    static let rec = Color(red: 0.957, green: 0.247, blue: 0.369)
    static let recDeep = Color(red: 0.882, green: 0.114, blue: 0.282)
    /// 渐变的浅头（rose-300），只和 rec、recDeep 搭着用
    static let roseLight = Color(red: 0.992, green: 0.643, blue: 0.686)

    /// 暖灰的一组（和设计稿的 warm-50…950 对应），深色时自动换成对应的暗色。
    static let warm50 = dynamic(light: (0.988, 0.984, 0.980), dark: (0.165, 0.149, 0.137))
    static let warm100 = dynamic(light: (0.957, 0.949, 0.937), dark: (0.137, 0.122, 0.110))
    static let warm200 = dynamic(light: (0.910, 0.894, 0.875), dark: (0.239, 0.216, 0.196))
    static let warm300 = dynamic(light: (0.843, 0.820, 0.796), dark: (0.306, 0.278, 0.251))
    static let warm400 = dynamic(light: (0.722, 0.690, 0.651), dark: (0.478, 0.439, 0.400))
    static let warm500 = dynamic(light: (0.588, 0.549, 0.506), dark: (0.588, 0.549, 0.506))
    static let warm600 = dynamic(light: (0.478, 0.439, 0.400), dark: (0.722, 0.690, 0.651))
    static let warm700 = dynamic(light: (0.380, 0.345, 0.314), dark: (0.843, 0.820, 0.796))
    static let warm800 = dynamic(light: (0.306, 0.278, 0.251), dark: (0.910, 0.894, 0.875))
    static let warm900 = dynamic(light: (0.239, 0.216, 0.196), dark: (0.957, 0.949, 0.937))
    /// 卡片、输入框里的「白」：深色时是比底色亮一级的暖黑。
    static let surface = dynamic(light: (1, 1, 1), dark: (0.196, 0.180, 0.165))

    static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(macOS)
        Color(NSColor(name: nil) { a in
            let d = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = d ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    static let graphite = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let paper = Color(red: 0.96, green: 0.93, blue: 0.87)
    /// 「没问题」的颜色：一种不扎眼的绿，只用在已连接、已就绪这类状态上。
    static let ok = Color(red: 0.42, green: 0.72, blue: 0.47)
    /// 区分说话人用的一组颜色：都在暖色和中性色里选。
    static let speakers: [Color] = [
        Color(red: 0.93, green: 0.62, blue: 0.16),   // 琥珀
        Color(red: 0.86, green: 0.38, blue: 0.30),   // 珊瑚
        Color(red: 0.42, green: 0.62, blue: 0.40),   // 鼠尾草绿
        Color(red: 0.66, green: 0.54, blue: 0.38),   // 沙
        Color(red: 0.70, green: 0.36, blue: 0.20),   // 赭
        Color(red: 0.52, green: 0.50, blue: 0.47),   // 暖灰
    ]
}

extension AppSettings.Appearance {
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}
