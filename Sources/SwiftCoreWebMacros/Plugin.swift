// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// The compiler plugin entry point registering every macro declared in
/// `SwiftCoreWeb/MacroDeclarations.swift`.
///
/// Implementations land in Part 2 (Macro Compiler Plugin, using
/// SwiftSyntax); this file wires the plugin so the package builds against
/// Part 1's macro declarations ahead of that.
@main
struct SwiftCoreWebMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ControllerMacro.self,
        RouteMethodMacro.self,
        ApiModelMacro.self
    ]
}
