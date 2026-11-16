import XCTest
@testable import MyHomeCore

final class VoiceFollowUpTests: XCTestCase {
    func testQuestionsReopenTheMic() {
        XCTAssertTrue(VoiceFollowUp.shouldListen(after: .ambiguous, enabled: true, turnsSoFar: 0, maxTurns: 3))
        XCTAssertTrue(VoiceFollowUp.shouldListen(after: .needsConfirmation, enabled: true, turnsSoFar: 2, maxTurns: 3))
    }

    func testFinishedRepliesDoNotReopen() {
        for kind: AssistantReply.Kind in [.executed, .status, .planned, .info, .error] {
            XCTAssertFalse(VoiceFollowUp.shouldListen(after: kind, enabled: true, turnsSoFar: 0, maxTurns: 3), "\(kind)")
        }
    }

    func testCapAndSwitchStopTheLoop() {
        XCTAssertFalse(VoiceFollowUp.shouldListen(after: .ambiguous, enabled: true, turnsSoFar: 3, maxTurns: 3))
        XCTAssertFalse(VoiceFollowUp.shouldListen(after: .ambiguous, enabled: false, turnsSoFar: 0, maxTurns: 3))
    }

    func testSettingsDefaultsAndClamp() {
        let defaults = UserDefaults(suiteName: "VoiceFollowUpTests-\(UUID().uuidString)")!
        XCTAssertTrue(AppSettings.voiceFollowUpEnabled(from: defaults))
        XCTAssertEqual(AppSettings.voiceFollowUpMaxTurns(from: defaults), AppSettings.defaultVoiceFollowUpMaxTurns)
        defaults.set(false, forKey: AppSettings.voiceFollowUpEnabledKey)
        defaults.set(99, forKey: AppSettings.voiceFollowUpMaxTurnsKey)
        XCTAssertFalse(AppSettings.voiceFollowUpEnabled(from: defaults))
        XCTAssertEqual(AppSettings.voiceFollowUpMaxTurns(from: defaults), AppSettings.voiceFollowUpMaxTurnsRange.upperBound)
    }
}
