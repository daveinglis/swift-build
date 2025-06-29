//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SWBUtil
import SWBCore
import SWBTaskExecution
import ArgumentParser

class TestEntryPointGenerationTaskAction: TaskAction {
    override class var toolIdentifier: String {
        "TestEntryPointGenerationTaskAction"
    }

    override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        do {
            let options = try Options.parse(Array(task.commandLineAsStrings.dropFirst()))

            var tests: [IndexStore.TestCaseClass] = []
            var objects: [Path] = []
            for linkerFilelist in options.linkerFilelist {
                let filelistContents = String(String(decoding: try executionDelegate.fs.read(linkerFilelist), as: UTF8.self))
                let entries = filelistContents.split(separator: "\n", omittingEmptySubsequences: true).map { Path($0) }.map {
                    for indexUnitBasePath in options.indexUnitBasePath {
                        if let remappedPath = generateIndexOutputPath(from: $0, basePath: indexUnitBasePath) {
                            return remappedPath
                        }
                    }
                    return $0
                }
                objects.append(contentsOf: entries)
            }
            let indexStoreAPI = try IndexStoreAPI(dylib: options.indexStoreLibraryPath)
            for indexStore in options.indexStore {
                let store = try IndexStore.open(store: indexStore, api: indexStoreAPI)
                let testInfo = try store.listTests(in: objects)
                tests.append(contentsOf: testInfo)
            }

            try executionDelegate.fs.write(options.output, contents: ByteString(encodingAsUTF8: """
            #if canImport(Testing)
            import Testing
            #endif
            
            \(testObservationFragment)
            
            import XCTest
            \(discoveredTestsFragment(tests: tests))

            @main
            @available(macOS 10.15, iOS 11, watchOS 4, tvOS 11, visionOS 1, *)
            @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
            struct Runner {
                private static func testingLibrary() -> String {
                    var iterator = CommandLine.arguments.makeIterator()
                    while let argument = iterator.next() {
                        if argument == "--testing-library", let libraryName = iterator.next() {
                            return libraryName.lowercased()
                        }
                    }

                    // Fallback if not specified: run XCTest (legacy behavior)
                    return "xctest"
                }
            
                private static func testOutputPath() -> String? {
                    var iterator = CommandLine.arguments.makeIterator()
                    while let argument = iterator.next() {
                        if argument == "--testing-output-path", let outputPath = iterator.next() {
                            return outputPath
                        }
                    }
                    return nil
                }
            
                #if os(Linux)
                @_silgen_name("$ss13_runAsyncMainyyyyYaKcF")
                private static func _runAsyncMain(_ asyncFun: @Sendable @escaping () async throws -> ())

                static func main() {
                    let testingLibrary = Self.testingLibrary()
                    #if canImport(Testing)
                    if testingLibrary == "swift-testing" {
                        _runAsyncMain {
                            await Testing.__swiftPMEntryPoint() as Never
                        }
                    }
                    #endif
                    if testingLibrary == "xctest" {
                        #if !os(Windows) && \(options.enableExperimentalTestOutput)
                        _ = Self.testOutputPath().map { SwiftPMXCTestObserver(testOutputPath: testOutputPath) }
                        #endif
                        #if os(WASI)
                        await XCTMain(__allDiscoveredTests()) as Never
                        #else
                        XCTMain(__allDiscoveredTests()) as Never
                        #endif
                    }
                }
                #else
                static func main() async {
                    let testingLibrary = Self.testingLibrary()
                    #if canImport(Testing)
                    if testingLibrary == "swift-testing" {
                        await Testing.__swiftPMEntryPoint() as Never
                    }
                    #endif
                    if testingLibrary == "xctest" {
                        #if !os(Windows) && \(options.enableExperimentalTestOutput)
                        _ = Self.testOutputPath().map { SwiftPMXCTestObserver(testOutputPath: testOutputPath) }
                        #endif
                        #if os(WASI)
                        await XCTMain(__allDiscoveredTests()) as Never
                        #else
                        XCTMain(__allDiscoveredTests()) as Never
                        #endif
                    }
                }
                #endif
            }
            """))

            return .succeeded
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
    }

    private struct Options: ParsableArguments {
        @Option var output: Path
        @Option var indexStoreLibraryPath: Path
        @Option var linkerFilelist: [Path]
        @Option var indexStore: [Path]
        @Option var indexUnitBasePath: [Path]
        @Flag var enableExperimentalTestOutput: Bool = false
    }

    private func discoveredTestsFragment(tests: [IndexStore.TestCaseClass]) -> String {
        var fragment = ""
        for moduleName in Set(tests.map { $0.module }).sorted() {
            fragment += "@testable import \(moduleName)\n"
        }
        fragment += """
        @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
        public func __allDiscoveredTests() -> [XCTestCaseEntry] {
            return [

        """
        for testClass in tests {

            let testTuples = testClass.testMethods.map { method in
                let basename = method.name.hasSuffix("()") ? String(method.name.dropLast(2)) : method.name
                if method.isAsync {
                    return "            (\"\(basename)\", asyncTest(\(testClass.name).\(basename)))"
                } else {
                    return "            (\"\(basename)\", \(testClass.name).\(basename))"
                }
            }
            fragment += "        testCase([\(testTuples.joined(separator: ",\n"))]),\n"
        }
        fragment += """
            ]
        }
        """
        return fragment
    }

    private var testObservationFragment: String =
        """
        #if !os(Windows) // Test observation is not supported on Windows
        import Foundation
        import XCTest
        
        public final class SwiftPMXCTestObserver: NSObject {
            let testOutputPath: String
        
            public init(testOutputPath: String) {
                self.testOutputPath = testOutputPath
                super.init()
                XCTestObservationCenter.shared.addTestObserver(self)
            }
        }
        
        extension SwiftPMXCTestObserver: XCTestObservation {
            private func write(record: any Encodable) {
                let lock = FileLock(at: URL(fileURLWithPath: self.testOutputPath + ".lock"))
                _ = try? lock.withLock {
                    self._write(record: record)
                }
            }
        
            private func _write(record: any Encodable) {
                if let data = try? JSONEncoder().encode(record) {
                    if let fileHandle = FileHandle(forWritingAtPath: self.testOutputPath) {
                        defer { fileHandle.closeFile() }
                        fileHandle.seekToEndOfFile()
                        fileHandle.write("\\n".data(using: .utf8)!)
                        fileHandle.write(data)
                    } else {
                        _ = try? data.write(to: URL(fileURLWithPath: self.testOutputPath))
                    }
                }
            }
        
            public func testBundleWillStart(_ testBundle: Bundle) {
                let record = TestBundleEventRecord(bundle: .init(testBundle), event: .start)
                write(record: TestEventRecord(bundleEvent: record))
            }
        
            public func testSuiteWillStart(_ testSuite: XCTestSuite) {
                let record = TestSuiteEventRecord(suite: .init(testSuite), event: .start)
                write(record: TestEventRecord(suiteEvent: record))
            }
        
            public func testCaseWillStart(_ testCase: XCTestCase) {
                let record = TestCaseEventRecord(testCase: .init(testCase), event: .start)
                write(record: TestEventRecord(caseEvent: record))
            }
        
            #if canImport(Darwin)
            public func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
                let record = TestCaseFailureRecord(testCase: .init(testCase), issue: .init(issue), failureKind: .unexpected)
                write(record: TestEventRecord(caseFailure: record))
            }
        
            public func testCase(_ testCase: XCTestCase, didRecord expectedFailure: XCTExpectedFailure) {
                let record = TestCaseFailureRecord(testCase: .init(testCase), issue: .init(expectedFailure.issue), failureKind: .expected(failureReason: expectedFailure.failureReason))
                write(record: TestEventRecord(caseFailure: record))
            }
            #else
            public func testCase(_ testCase: XCTestCase, didFailWithDescription description: String, inFile filePath: String?, atLine lineNumber: Int) {
                let issue = TestIssue(description: description, inFile: filePath, atLine: lineNumber)
                let record = TestCaseFailureRecord(testCase: .init(testCase), issue: issue, failureKind: .unexpected)
                write(record: TestEventRecord(caseFailure: record))
            }
            #endif
        
            public func testCaseDidFinish(_ testCase: XCTestCase) {
                let record = TestCaseEventRecord(testCase: .init(testCase), event: .finish)
                write(record: TestEventRecord(caseEvent: record))
            }
        
            #if canImport(Darwin)
            public func testSuite(_ testSuite: XCTestSuite, didRecord issue: XCTIssue) {
                let record = TestSuiteFailureRecord(suite: .init(testSuite), issue: .init(issue), failureKind: .unexpected)
                write(record: TestEventRecord(suiteFailure: record))
            }
        
            public func testSuite(_ testSuite: XCTestSuite, didRecord expectedFailure: XCTExpectedFailure) {
                let record = TestSuiteFailureRecord(suite: .init(testSuite), issue: .init(expectedFailure.issue), failureKind: .expected(failureReason: expectedFailure.failureReason))
                write(record: TestEventRecord(suiteFailure: record))
            }
            #else
            public func testSuite(_ testSuite: XCTestSuite, didFailWithDescription description: String, inFile filePath: String?, atLine lineNumber: Int) {
                let issue = TestIssue(description: description, inFile: filePath, atLine: lineNumber)
                let record = TestSuiteFailureRecord(suite: .init(testSuite), issue: issue, failureKind: .unexpected)
                write(record: TestEventRecord(suiteFailure: record))
            }
            #endif
        
            public func testSuiteDidFinish(_ testSuite: XCTestSuite) {
                let record = TestSuiteEventRecord(suite: .init(testSuite), event: .finish)
                write(record: TestEventRecord(suiteEvent: record))
            }
        
            public func testBundleDidFinish(_ testBundle: Bundle) {
                let record = TestBundleEventRecord(bundle: .init(testBundle), event: .finish)
                write(record: TestEventRecord(bundleEvent: record))
            }
        }
        
        // FIXME: Copied from `Lock.swift` in TSCBasic, would be nice if we had a better way
        
        #if canImport(Glibc)
        @_exported import Glibc
        #elseif canImport(Musl)
        @_exported import Musl
        #elseif os(Windows)
        @_exported import CRT
        @_exported import WinSDK
        #elseif os(WASI)
        @_exported import WASILibc
        #elseif canImport(Android)
        @_exported import Android
        #else
        @_exported import Darwin.C
        #endif
        
        import Foundation
        
        public final class FileLock {
          #if os(Windows)
            private var handle: HANDLE?
          #else
            private var fileDescriptor: CInt?
          #endif
        
            private let lockFile: URL
        
            public init(at lockFile: URL) {
                self.lockFile = lockFile
            }
        
            public func lock() throws {
              #if os(Windows)
                if handle == nil {
                    let h: HANDLE = lockFile.path.withCString(encodedAs: UTF16.self, {
                        CreateFileW(
                            $0,
                            UInt32(GENERIC_READ) | UInt32(GENERIC_WRITE),
                            UInt32(FILE_SHARE_READ) | UInt32(FILE_SHARE_WRITE),
                            nil,
                            DWORD(OPEN_ALWAYS),
                            DWORD(FILE_ATTRIBUTE_NORMAL),
                            nil
                        )
                    })
                    if h == INVALID_HANDLE_VALUE {
                        throw FileSystemError(errno: Int32(GetLastError()), lockFile)
                    }
                    self.handle = h
                }
                var overlapped = OVERLAPPED()
                overlapped.Offset = 0
                overlapped.OffsetHigh = 0
                overlapped.hEvent = nil
                if !LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0,
                                   UInt32.max, UInt32.max, &overlapped) {
                        throw ProcessLockError.unableToAquireLock(errno: Int32(GetLastError()))
                    }
              #elseif os(WASI)
                // WASI doesn't support flock
              #else
                if fileDescriptor == nil {
                    let fd = open(lockFile.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o666)
                    if fd == -1 {
                        fatalError("errno: \\(errno), lockFile: \\(lockFile)")
                    }
                    self.fileDescriptor = fd
                }
                while true {
                    if flock(fileDescriptor!, LOCK_EX) == 0 {
                        break
                    }
                    if errno == EINTR { continue }
                    fatalError("unable to acquire lock, errno: \\(errno)")
                }
              #endif
            }
        
            public func unlock() {
              #if os(Windows)
                var overlapped = OVERLAPPED()
                overlapped.Offset = 0
                overlapped.OffsetHigh = 0
                overlapped.hEvent = nil
                UnlockFileEx(handle, 0, UInt32.max, UInt32.max, &overlapped)
              #elseif os(WASI)
                // WASI doesn't support flock
              #else
                guard let fd = fileDescriptor else { return }
                flock(fd, LOCK_UN)
              #endif
            }
        
            deinit {
              #if os(Windows)
                guard let handle = handle else { return }
                CloseHandle(handle)
              #elseif os(WASI)
                // WASI doesn't support flock
              #else
                guard let fd = fileDescriptor else { return }
                close(fd)
              #endif
            }
        
            public func withLock<T>(_ body: () throws -> T) throws -> T {
                try lock()
                defer { unlock() }
                return try body()
            }
        
            public func withLock<T>(_ body: () async throws -> T) async throws -> T {
                try lock()
                defer { unlock() }
                return try await body()
            }
        }
        
        // FIXME: Copied from `XCTEvents.swift`, would be nice if we had a better way
        
        struct TestEventRecord: Codable {
            let caseFailure: TestCaseFailureRecord?
            let suiteFailure: TestSuiteFailureRecord?
        
            let bundleEvent: TestBundleEventRecord?
            let suiteEvent: TestSuiteEventRecord?
            let caseEvent: TestCaseEventRecord?
        
            init(
                caseFailure: TestCaseFailureRecord? = nil,
                suiteFailure: TestSuiteFailureRecord? = nil,
                bundleEvent: TestBundleEventRecord? = nil,
                suiteEvent: TestSuiteEventRecord? = nil,
                caseEvent: TestCaseEventRecord? = nil
            ) {
                self.caseFailure = caseFailure
                self.suiteFailure = suiteFailure
                self.bundleEvent = bundleEvent
                self.suiteEvent = suiteEvent
                self.caseEvent = caseEvent
            }
        }
        
        // MARK: - Records
        
        struct TestAttachment: Codable {
            let name: String?
            // TODO: Handle `userInfo: [AnyHashable : Any]?`
            let uniformTypeIdentifier: String
            let payload: Data?
        }
        
        struct TestBundleEventRecord: Codable {
            let bundle: TestBundle
            let event: TestEvent
        }
        
        struct TestCaseEventRecord: Codable {
            let testCase: TestCase
            let event: TestEvent
        }
        
        struct TestCaseFailureRecord: Codable, CustomStringConvertible {
            let testCase: TestCase
            let issue: TestIssue
            let failureKind: TestFailureKind
        
            var description: String {
                return "\\(issue.sourceCodeContext.description)\\(testCase) \\(issue.compactDescription)"
            }
        }
        
        struct TestSuiteEventRecord: Codable {
            let suite: TestSuiteRecord
            let event: TestEvent
        }
        
        struct TestSuiteFailureRecord: Codable {
            let suite: TestSuiteRecord
            let issue: TestIssue
            let failureKind: TestFailureKind
        }
        
        // MARK: Primitives
        
        struct TestBundle: Codable {
            let bundleIdentifier: String?
            let bundlePath: String
        }
        
        struct TestCase: Codable {
            let name: String
        }
        
        struct TestErrorInfo: Codable {
            let description: String
            let type: String
        }
        
        enum TestEvent: Codable {
            case start
            case finish
        }
        
        enum TestFailureKind: Codable, Equatable {
            case unexpected
            case expected(failureReason: String?)
        
            var isExpected: Bool {
                switch self {
                case .expected: return true
                case .unexpected: return false
                }
            }
        }
        
        struct TestIssue: Codable {
            let type: TestIssueType
            let compactDescription: String
            let detailedDescription: String?
            let associatedError: TestErrorInfo?
            let sourceCodeContext: TestSourceCodeContext
            let attachments: [TestAttachment]
        }
        
        enum TestIssueType: Codable {
            case assertionFailure
            case performanceRegression
            case system
            case thrownError
            case uncaughtException
            case unmatchedExpectedFailure
            case unknown
        }
        
        struct TestLocation: Codable, CustomStringConvertible {
            let file: String
            let line: Int
        
            var description: String {
                return "\\(file):\\(line) "
            }
        }
        
        struct TestSourceCodeContext: Codable, CustomStringConvertible {
            let callStack: [TestSourceCodeFrame]
            let location: TestLocation?
        
            var description: String {
                return location?.description ?? ""
            }
        }
        
        struct TestSourceCodeFrame: Codable {
            let address: UInt64
            let symbolInfo: TestSourceCodeSymbolInfo?
            let symbolicationError: TestErrorInfo?
        }
        
        struct TestSourceCodeSymbolInfo: Codable {
            let imageName: String
            let symbolName: String
            let location: TestLocation?
        }
        
        struct TestSuiteRecord: Codable {
            let name: String
        }
        
        // MARK: XCTest compatibility
        
        extension TestIssue {
            init(description: String, inFile filePath: String?, atLine lineNumber: Int) {
                let location: TestLocation?
                if let filePath = filePath {
                    location = .init(file: filePath, line: lineNumber)
                } else {
                    location = nil
                }
                self.init(type: .assertionFailure, compactDescription: description, detailedDescription: description, associatedError: nil, sourceCodeContext: .init(callStack: [], location: location), attachments: [])
            }
        }
        
        import XCTest
        
        #if canImport(Darwin) // XCTAttachment is unavailable in swift-corelibs-xctest.
        extension TestAttachment {
            init(_ attachment: XCTAttachment) {
                self.init(
                    name: attachment.name,
                    uniformTypeIdentifier: attachment.uniformTypeIdentifier,
                    payload: attachment.value(forKey: "payload") as? Data
                )
            }
        }
        #endif
        
        extension TestBundle {
            init(_ testBundle: Bundle) {
                self.init(
                    bundleIdentifier: testBundle.bundleIdentifier,
                    bundlePath: testBundle.bundlePath
                )
            }
        }
        
        extension TestCase {
            init(_ testCase: XCTestCase) {
                self.init(name: testCase.name)
            }
        }
        
        extension TestErrorInfo {
            init(_ error: any Swift.Error) {
                self.init(description: "\\(error)", type: "\\(Swift.type(of: error))")
            }
        }
        
        #if canImport(Darwin) // XCTIssue is unavailable in swift-corelibs-xctest.
        extension TestIssue {
            init(_ issue: XCTIssue) {
                self.init(
                    type: .init(issue.type),
                    compactDescription: issue.compactDescription,
                    detailedDescription: issue.detailedDescription,
                    associatedError: issue.associatedError.map { .init($0) },
                    sourceCodeContext: .init(issue.sourceCodeContext),
                    attachments: issue.attachments.map { .init($0) }
                )
            }
        }
        
        extension TestIssueType {
            init(_ type: XCTIssue.IssueType) {
                switch type {
                case .assertionFailure: self = .assertionFailure
                case .thrownError: self = .thrownError
                case .uncaughtException: self = .uncaughtException
                case .performanceRegression: self = .performanceRegression
                case .system: self = .system
                case .unmatchedExpectedFailure: self = .unmatchedExpectedFailure
                @unknown default: self = .unknown
                }
            }
        }
        #endif
        
        #if canImport(Darwin) // XCTSourceCodeLocation/XCTSourceCodeContext/XCTSourceCodeFrame/XCTSourceCodeSymbolInfo is unavailable in swift-corelibs-xctest.
        extension TestLocation {
            init(_ location: XCTSourceCodeLocation) {
                self.init(
                    file: location.fileURL.absoluteString,
                    line: location.lineNumber
                )
            }
        }
        
        extension TestSourceCodeContext {
            init(_ context: XCTSourceCodeContext) {
                self.init(
                    callStack: context.callStack.map { .init($0) },
                    location: context.location.map { .init($0) }
                )
            }
        }
        
        extension TestSourceCodeFrame {
            init(_ frame: XCTSourceCodeFrame) {
                self.init(
                    address: frame.address,
                    symbolInfo: (try? frame.symbolInfo()).map { .init($0) },
                    symbolicationError: frame.symbolicationError.map { .init($0) }
                )
            }
        }
        
        extension TestSourceCodeSymbolInfo {
            init(_ symbolInfo: XCTSourceCodeSymbolInfo) {
                self.init(
                    imageName: symbolInfo.imageName,
                    symbolName: symbolInfo.symbolName,
                    location: symbolInfo.location.map { .init($0) }
                )
            }
        }
        #endif
        
        extension TestSuiteRecord {
            init(_ testSuite: XCTestSuite) {
                self.init(name: testSuite.name)
            }
        }
        #endif
        """
}
