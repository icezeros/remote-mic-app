import Foundation
import SayAllControlKit
import Testing

@Suite("电脑控制分级策略")
struct ComputerControlPolicyTests {
    @Test("功能未启用时一律拒绝")
    func disabledFeatureDeniesEverything() {
        let policy = ControlPolicy(isEnabled: false)
        #expect(policy.decision(for: .listRunningApps, bundleIdentifier: "com.apple.Safari") == .deny)
        #expect(policy.decision(for: .typeText, bundleIdentifier: "com.apple.Safari") == .deny)
    }

    @Test("只读工具默认自动执行")
    func readToolsRunWithoutPrompt() {
        let policy = ControlPolicy(isEnabled: true)
        #expect(policy.decision(for: .listRunningApps, bundleIdentifier: nil) == .allow)
        #expect(policy.decision(for: .getFrontmostApp, bundleIdentifier: nil) == .allow)
    }

    @Test("输入注入默认需要确认")
    func inputToolsRequireConfirmation() {
        let policy = ControlPolicy(isEnabled: true)
        #expect(policy.decision(for: .typeText, bundleIdentifier: "com.apple.Safari") == .confirm)
        #expect(policy.decision(for: .click, bundleIdentifier: "com.apple.Safari") == .confirm)
    }

    @Test("脚本执行默认关闭")
    func privilegedToolsDeniedByDefault() {
        let policy = ControlPolicy(isEnabled: true)
        #expect(policy.decision(for: .runAppleScript, bundleIdentifier: "com.apple.Terminal") == .deny)
    }

    @Test("记住授权后同一应用不再弹窗")
    func rememberedGrantSkipsConfirmation() {
        var policy = ControlPolicy(isEnabled: true)
        policy.remember(.typeText, bundleIdentifier: "com.apple.Safari")
        #expect(policy.decision(for: .typeText, bundleIdentifier: "com.apple.Safari") == .allow)
        // 另一个应用仍然要确认。
        #expect(policy.decision(for: .typeText, bundleIdentifier: "com.apple.Notes") == .confirm)
    }

    @Test("前台应用缺失且未允许后台注入时拒绝")
    func missingForegroundAppDeniesInjection() {
        let policy = ControlPolicy(isEnabled: true)
        #expect(policy.decision(for: .pressKey, bundleIdentifier: nil) == .deny)
        var relaxed = policy
        relaxed.allowBackgroundInjection = true
        #expect(relaxed.decision(for: .pressKey, bundleIdentifier: nil) == .confirm)
    }

    @Test("收紧策略会清掉该层级的记住授权")
    func tighteningClearsGrants() {
        var policy = ControlPolicy(isEnabled: true)
        policy.remember(.typeText, bundleIdentifier: "com.apple.Safari")
        policy.pruneGrants(whenTighteningTo: .input, decision: .deny)
        #expect(policy.rememberedGrants.isEmpty)
    }

    @Test("审计摘要不记录原始文字")
    func auditDigestRedactsTypedText() {
        let digest = ControlAuditDigest.describe(
            tool: .typeText,
            arguments: ["text": "这是用户的私密内容" as any Sendable]
        )
        #expect(digest.contains("chars"))
        #expect(!digest.contains("私密"))
    }

    @Test("工具目录覆盖全部工具且层级正确")
    func toolCatalogIsComplete() {
        #expect(ControlToolDescriptor.all.count == ControlToolID.allCases.count)
        #expect(ControlToolID.runAppleScript.tier == .privileged)
        #expect(ControlToolID.listRunningApps.tier == .read)
    }
}
