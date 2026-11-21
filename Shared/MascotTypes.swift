import Foundation

/// 小豆的样子跟着吧唧录音库的状态和录音豆的电量走。
enum MascotMood: Equatable {
    case sleeping    // 录音豆没连上
    case idle        // 待命
    case listening   // 正在录音
    case writing     // 正在把录音转成文字：埋头、两只手轮流敲
    case thinking    // 正在整理纪要：歪着头左看右看、一只手举着
    case happy       // 刚处理完一条、刚配对成功
}

/// 录音豆的电量状态，决定待命时的表情
enum MascotPower: Equatable {
    case unknown
    case charging(Int)   // 放在充电仓里，带当前电量
    case low             // 20% 以下
    case mid
    case full            // 80% 以上

    init(battery: Int, charging: Bool) {
        if charging { self = .charging(battery) }
        else if battery <= 0 { self = .unknown }
        else if battery < 20 { self = .low }
        else if battery >= 80 { self = .full }
        else { self = .mid }
    }
}
