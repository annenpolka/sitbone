// Logging.swift — SitboneCore用 os.Logger カテゴリ宣言
// ADR-0018に基づく細分化カテゴリ設計

import os

extension Logger {
    /// FocusState遷移
    static let coreState = Logger(subsystem: "com.sitbone", category: "core.state")

    /// セッション境界、プロファイル切替、Ghost Teacher、Site再分類
    static let coreSession = Logger(subsystem: "com.sitbone", category: "core.session")

    /// システムスリープ/ウェイク、アプリ起動/終了
    static let coreLifecycle = Logger(subsystem: "com.sitbone", category: "core.lifecycle")

    /// センサー融合のtick詳細とstatus変化
    /// PresenceArbiter(SitboneCore)が emit するためSitboneCoreで宣言する
    static let sensorsPresence = Logger(subsystem: "com.sitbone", category: "sensors.presence")
}
