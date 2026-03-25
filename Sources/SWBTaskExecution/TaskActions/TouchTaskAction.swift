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

public import SWBCore
import SWBUtil

/// Concrete implementation of task for touching a file or directory to update its modification timestamp.
public final class TouchTaskAction: TaskAction {
    /// The tool identifier registered with llbuild. As with other builtins (e.g. `concatenate`),
    /// this is the unprefixed form of the `builtin-touch` command line emitted by `TouchToolSpec`.
    public override class var toolIdentifier: String {
        return "touch"
    }

    public override func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        // Expected command line: ["builtin-touch", <path>] — exactly one path argument.
        let arguments = Array(task.commandLineAsStrings.dropFirst())  // drop program name "builtin-touch"
        guard arguments.count == 1, let pathString = arguments.first else {
            outputDelegate.emitError("expected a single path argument to builtin-touch")
            return .failed
        }

        let path = Path(pathString)
        let fs = executionDelegate.fs

        // Unlike `/usr/bin/touch`, this action deliberately does not create the path if it is
        // missing (the spec previously passed `-c` to suppress creation). The product being
        // touched is always expected to exist already, so a missing path indicates a build
        // graph error and is reported as a failure rather than silently created.
        guard fs.exists(path) else {
            outputDelegate.emitError("path does not exist: \(path.str)")
            return .failed
        }

        // Touch the file/directory to update its modification timestamp
        do {
            try fs.touch(path)
            return .succeeded
        } catch {
            outputDelegate.emitError("failed to touch \(path.str): \(error)")
            return .failed
        }
    }
}
