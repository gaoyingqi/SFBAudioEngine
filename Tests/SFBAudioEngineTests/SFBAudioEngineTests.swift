//
// SPDX-FileCopyrightText: 2012 Stephen F. Booth <contact@sbooth.dev>
// SPDX-License-Identifier: MIT
//
// Part of https://github.com/sbooth/SFBAudioEngine
//

import XCTest
@testable import SFBAudioEngine

final class SFBAudioEngineTests: XCTestCase {
    func testInputSourceFromData() throws {
        let input = InputSource(data: Data(repeating: 0xfe, count: 16))
        XCTAssertEqual(input.isOpen, true)
        XCTAssertEqual(input.supportsSeeking, true)
        XCTAssertEqual(try input.offset, 0)
        let i: UInt8 = try input.read()
        XCTAssertEqual(i, 0xfe)
        XCTAssertEqual(try input.offset, 1)
        XCTAssertEqual(try input.length, 16)
    }

    func testOutputTargetFromData() throws {
        let output = OutputTarget.makeForData()
        XCTAssertEqual(output.isOpen, true)
        XCTAssertEqual(output.supportsSeeking, true)
        var i: UInt32 = 0x12345678
        XCTAssertEqual(try output.write(&i, length: MemoryLayout<UInt32>.size), MemoryLayout<UInt32>.size)
        try output.seek(toOffset: 0)
        XCTAssertEqual(try output.read(&i, length: MemoryLayout<UInt32>.size), MemoryLayout<UInt32>.size)
        XCTAssertEqual(i, 0x12345678)
    }

    func testAudioEngineConfigurationChangeHandlerCatchesObjectiveCExceptions() throws {
        // 简体中文注释：回归保护 iOS 音频设备变化时 AVAudioEngine 抛异常不能穿过 noexcept 边界。
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let audioPlayerURL = packageRootURL
            .appendingPathComponent("Sources/CSFBAudioEngine/Player/AudioPlayer.mm")
        let source = try String(contentsOf: audioPlayerURL, encoding: .utf8)

        guard let handlerStart = source.range(of: "void sfb::AudioPlayer::handleAudioEngineConfigurationChange") else {
            return XCTFail("Missing handleAudioEngineConfigurationChange implementation")
        }
        let handlerTail = source[handlerStart.lowerBound...]
        guard let handlerEnd = handlerTail.range(of: "#if TARGET_OS_IPHONE") else {
            return XCTFail("Unable to isolate handleAudioEngineConfigurationChange implementation")
        }
        let handlerSource = handlerTail[..<handlerEnd.lowerBound]

        let tryRange = try XCTUnwrap(handlerSource.range(of: "@try"))
        let catchRange = try XCTUnwrap(handlerSource.range(of: "@catch (NSException *exception)"))
        XCTAssertLessThan(tryRange.lowerBound, catchRange.lowerBound)

        // 简体中文注释：确保真实会触发崩溃的 AVAudioEngine 图重配操作都被 @try 包住。
        let protectedOperations = [
            "[engine_ disconnectNodeInput:outputNode bus:0];",
            "[engine_ connect:mixerNode to:outputNode format:outputNodeOutputFormat];",
            "[engine_ prepare];"
        ]
        for operation in protectedOperations {
            let operationRange = try XCTUnwrap(handlerSource.range(of: operation))
            XCTAssertGreaterThan(operationRange.lowerBound, tryRange.lowerBound)
            XCTAssertLessThan(operationRange.upperBound, catchRange.lowerBound)
        }

        // 简体中文注释：异常路径必须停止引擎、清播放标记，并把异常转换成 delegate 错误。
        let errorBranchRange = try XCTUnwrap(handlerSource.range(of: "if (configurationChangeError != nil)"))
        let catchBody = handlerSource[catchRange.lowerBound..<errorBranchRange.lowerBound]
        XCTAssertTrue(catchBody.contains("[engine_ stop];"))
        XCTAssertTrue(catchBody.contains("clearFlags(Flags::engineIsRunning | Flags::isPlaying);"))
        XCTAssertTrue(catchBody.contains("configurationChangeError ="))
        XCTAssertTrue(catchBody.contains("errorWithDomain:SFBAudioPlayerErrorDomain"))

        // 简体中文注释：delegate 回调不能在持有 engineMutex_ 时发生，且错误上报后必须退出 handler。
        let errorBranch = handlerSource[errorBranchRange.lowerBound...]
        let unlockRange = try XCTUnwrap(errorBranch.range(of: "lock.unlock();"))
        let callbackRange = try XCTUnwrap(errorBranch.range(of: "encounteredError:configurationChangeError"))
        let returnRange = try XCTUnwrap(errorBranch.range(of: "return;"))
        XCTAssertLessThan(unlockRange.upperBound, callbackRange.lowerBound)
        XCTAssertLessThan(callbackRange.upperBound, returnRange.lowerBound)
    }
}
