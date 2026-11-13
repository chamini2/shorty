import AppKit
import XCTest
@testable import ShortyCore

final class ConfigurationTests: XCTestCase {
    func testParsesHotkey() throws {
        let combo = try KeyCombo.parse("cmd+option+1")
        XCTAssertEqual(combo.normalizedValue, "cmd+option+1")
    }

    func testParsesNumpadKeys() throws {
        XCTAssertEqual(try KeyCombo.parse("cmd+option+numpad1").normalizedValue, "cmd+option+numpad1")
        XCTAssertEqual(try KeyCombo.parse("cmd+keypad1").normalizedValue, "cmd+numpad1")
        XCTAssertEqual(try KeyCombo.parse("ctrl+numpadenter").normalizedValue, "ctrl+numpadenter")
    }

    func testNumpadAndTopRowDigitsAreDifferentKeys() throws {
        let numpad = try KeyCombo.parse("cmd+option+numpad1")
        let topRow = try KeyCombo.parse("cmd+option+1")

        XCTAssertNotEqual(numpad.keyCode, topRow.keyCode)
        XCTAssertEqual(numpad.modifiers, topRow.modifiers)
    }

    func testLoadsValidYAMLDictionaryConfiguration() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              project-a:
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
                title-regex: project-a
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(configuration.shortcuts.count, 1)
        XCTAssertEqual(configuration.shortcuts.first?.id, "project-a")
        XCTAssertEqual(configuration.shortcuts.first?.hotKey.normalizedValue, "cmd+option+1")
    }

    func testLoadsYMLConfiguration() throws {
        let url = try temporaryConfigURL(
            extension: "yml",
            contents: """
            shortcuts:
              project-a:
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(configuration.shortcuts.count, 1)
        XCTAssertEqual(configuration.shortcuts.first?.id, "project-a")
    }

    func testLoadsGroupedSnippets() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              project-a:
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
            snippets:
              Work:
                Zebra: Last alphabetically but first in config
                Greeting: Hello there
                Rich Example: Plain fallback text
              Personal:
                Address: 123 Example St
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(configuration.snippetGroups.count, 2)
        XCTAssertEqual(configuration.snippetGroups.map(\.title), ["Work", "Personal"])
        XCTAssertEqual(configuration.snippetGroups[0].snippets.map(\.title), ["Zebra", "Greeting", "Rich Example"])
        XCTAssertEqual(configuration.snippetGroups[0].snippets[1].content, "Hello there")
    }

    func testAllowsSnippetOnlyConfiguration() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            snippets:
              Work:
                Greeting: Hello there
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertTrue(configuration.shortcuts.isEmpty)
        XCTAssertEqual(configuration.snippetGroups.first?.snippets.first?.title, "Greeting")
    }

    func testRejectsArrayConfiguration() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              - id: project-a
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
                title-regex: project-a
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url))
    }

    func testRejectsBoundClipboardMenuHotkey() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              reserved:
                hotkey: cmd+shift+v
                bundle-id: com.microsoft.VSCode
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url)) { error in
            XCTAssertTrue(String(describing: error).contains("is used by both"))
        }
    }

    func testRejectsBoundSnippetMenuHotkey() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              reserved:
                hotkey: cmd+shift+b
                bundle-id: com.microsoft.VSCode
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url)) { error in
            XCTAssertTrue(String(describing: error).contains("is used by both"))
        }
    }

    func testRejectsBoundTextCommandHotkey() throws {
        let hotkeys = ["alt+space", "option+space"]

        for hotkey in hotkeys {
            let url = try temporaryConfigURL(
                extension: "yaml",
                contents: """
                shortcuts:
                  reserved:
                    hotkey: \(hotkey)
                    bundle-id: com.microsoft.VSCode
                """
            )

            XCTAssertThrowsError(try ConfigurationLoader.load(from: url), "Expected \(hotkey) to conflict") { error in
                XCTAssertTrue(String(describing: error).contains("is used by both"))
            }
        }
    }

    func testRejectsBoundWindowSwitcherHotkey() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              reserved:
                hotkey: cmd+tab
                bundle-id: com.microsoft.VSCode
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url)) { error in
            XCTAssertTrue(String(describing: error).contains("is used by both"))
        }
    }

    func testRejectsBoundCurrentAppWindowSwitcherHotkey() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              reserved:
                hotkey: cmd+grave
                bundle-id: com.microsoft.VSCode
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url)) { error in
            XCTAssertTrue(String(describing: error).contains("is used by both"))
        }
    }

    func testRejectsBoundWindowMovementHotkey() throws {
        let hotkeys = [
            "ctrl+option+left",
            "ctrl+option+right",
            "ctrl+option+cmd+up",
            "ctrl+option+cmd+left",
            "ctrl+option+cmd+right",
        ]

        for hotkey in hotkeys {
            let url = try temporaryConfigURL(
                extension: "yaml",
                contents: """
                shortcuts:
                  reserved:
                    hotkey: \(hotkey)
                    bundle-id: com.microsoft.VSCode
                """
            )

            XCTAssertThrowsError(try ConfigurationLoader.load(from: url), "Expected \(hotkey) to conflict") { error in
                XCTAssertTrue(String(describing: error).contains("is used by both"))
            }
        }
    }

    func testLoadsExecutablePathPrefixMatcherConfiguration() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              portable-vscode:
                hotkey: cmd+option+1
                executable-path-prefix: /Applications/VSCode-Portable.app/
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(configuration.shortcuts.count, 1)
        XCTAssertEqual(configuration.shortcuts.first?.id, "portable-vscode")
        XCTAssertEqual(configuration.shortcuts.first?.matcher.executablePathPrefix, "/Applications/VSCode-Portable.app/")
    }

    func testExecutablePathPrefixUsesLiteralPrefix() {
        let matcher = WindowMatcher(
            bundleID: nil,
            appNameRegex: nil,
            executablePathPrefix: "/Applications/Cursor.app/",
            titleRegex: nil,
            titleContains: nil,
            documentRegex: nil,
            urlRegex: nil,
            identifierRegex: nil,
            windowIndex: 0
        )

        XCTAssertTrue(
            matcher.matchesApplication(
                app: NSRunningApplication.current,
                executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor"
            )
        )
        XCTAssertFalse(
            matcher.matchesApplication(
                app: NSRunningApplication.current,
                executablePath: "/Applications/CursorXapp/Contents/MacOS/Cursor"
            )
        )
    }

    func testAppOnlyMatcherUsesApplicationActivation() throws {
        let matcher = WindowMatcher(
            bundleID: "com.mitchellh.ghostty",
            appNameRegex: nil,
            executablePathPrefix: nil,
            titleRegex: nil,
            titleContains: nil,
            documentRegex: nil,
            urlRegex: nil,
            identifierRegex: nil,
            windowIndex: 0
        )

        XCTAssertTrue(matcher.usesApplicationActivation)
    }

    func testWindowSpecificMatcherDoesNotUseApplicationActivation() throws {
        let titleMatcher = WindowMatcher(
            bundleID: "com.mitchellh.ghostty",
            appNameRegex: nil,
            executablePathPrefix: nil,
            titleRegex: nil,
            titleContains: "project",
            documentRegex: nil,
            urlRegex: nil,
            identifierRegex: nil,
            windowIndex: 0
        )
        let indexMatcher = WindowMatcher(
            bundleID: "com.mitchellh.ghostty",
            appNameRegex: nil,
            executablePathPrefix: nil,
            titleRegex: nil,
            titleContains: nil,
            documentRegex: nil,
            urlRegex: nil,
            identifierRegex: nil,
            windowIndex: 1
        )

        XCTAssertFalse(titleMatcher.usesApplicationActivation)
        XCTAssertFalse(indexMatcher.usesApplicationActivation)
    }

    func testRejectsDuplicateHotkeys() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              a:
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
              b:
                hotkey: cmd+option+1
                bundle-id: com.apple.Terminal
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url))
    }

    func testRejectsInvalidRegex() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              broken:
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
                title-regex: (
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url))
    }

    func testUsesDefaultBindingsWithoutHotkeysBlock() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              project-a:
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(configuration.bindings, .default)
        XCTAssertEqual(configuration.bindings.commandBox, DefaultHotKeys.commandBox)
    }

    func testRebindsBuiltInHotkey() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            hotkeys:
              command-box: cmd+shift+space

            shortcuts:
              project-a:
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(configuration.bindings.commandBox?.normalizedValue, "cmd+shift+space")
        XCTAssertEqual(configuration.bindings.clipboardMenu, DefaultHotKeys.clipboardMenu)
    }

    func testUnbindingFreesTheHotkeyForAShortcut() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            hotkeys:
              command-box: off

            shortcuts:
              reserved:
                hotkey: option+space
                bundle-id: com.microsoft.VSCode
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertNil(configuration.bindings.commandBox)
        XCTAssertEqual(configuration.shortcuts.first?.hotKey.normalizedValue, "option+space")
    }

    func testDisablingAGroupUnbindsEveryKeyInIt() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            hotkeys:
              window-movement: off
              window-switcher: off

            shortcuts:
              reserved:
                hotkey: ctrl+option+left
                bundle-id: com.microsoft.VSCode
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertFalse(configuration.bindings.windowMovementEnabled)
        XCTAssertFalse(configuration.bindings.windowSwitcherEnabled)
        XCTAssertEqual(configuration.shortcuts.first?.hotKey.normalizedValue, "ctrl+option+left")
    }

    func testRebindsOneKeyOfAGroupAndKeepsTheRest() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            hotkeys:
              window-movement:
                left-half: ctrl+cmd+left
                maximize: off

            shortcuts:
              project-a:
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(configuration.bindings.moveWindowLeftHalf?.normalizedValue, "cmd+ctrl+left")
        XCTAssertNil(configuration.bindings.maximizeWindow)
        XCTAssertEqual(configuration.bindings.moveWindowRightHalf, DefaultHotKeys.moveWindowRightHalf)
        XCTAssertTrue(configuration.bindings.windowMovementEnabled)
    }

    func testAcceptsHotkeyOnlyConfiguration() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            hotkeys:
              window-switcher: off
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertTrue(configuration.shortcuts.isEmpty)
        XCTAssertFalse(configuration.bindings.windowSwitcherEnabled)
    }

    func testRejectsUnknownBindingName() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            hotkeys:
              command-bx: cmd+j
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url)) { error in
            XCTAssertTrue(String(describing: error).contains("Unknown hotkey binding"))
        }
    }

    func testRejectsSwitcherBindingWithoutModifier() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            hotkeys:
              window-switcher:
                all-windows: f13
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url)) { error in
            XCTAssertTrue(String(describing: error).contains("needs a modifier"))
        }
    }

    func testRejectsMovedSettingsKeys() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            settings:
              command-palette: false

            shortcuts:
              project-a:
                hotkey: cmd+option+1
                bundle-id: com.microsoft.VSCode
            """
        )

        XCTAssertThrowsError(try ConfigurationLoader.load(from: url)) { error in
            XCTAssertTrue(String(describing: error).contains("hotkeys.command-box"))
        }
    }

    func testDigitShortcutAlsoClaimsItsKeypadTwin() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              slack:
                hotkey: cmd+option+1
                bundle-id: com.tinyspeck.slackmacgap
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(
            configuration.shortcuts.first?.aliasHotKeys.map(\.normalizedValue),
            ["cmd+option+numpad1"]
        )
    }

    func testExplicitKeypadBindingWinsOverTheAlias() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              slack:
                hotkey: cmd+option+1
                bundle-id: com.tinyspeck.slackmacgap
              finder:
                hotkey: cmd+option+numpad1
                bundle-id: com.apple.finder
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        let slack = configuration.shortcuts.first { $0.id == "slack" }
        let finder = configuration.shortcuts.first { $0.id == "finder" }

        XCTAssertEqual(slack?.aliasHotKeys, [])
        XCTAssertEqual(finder?.hotKey.normalizedValue, "cmd+option+numpad1")
    }

    func testBuiltInBindingBlocksAShortcutAlias() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            hotkeys:
              command-box: cmd+option+numpad1

            shortcuts:
              slack:
                hotkey: cmd+option+1
                bundle-id: com.tinyspeck.slackmacgap
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(configuration.shortcuts.first?.aliasHotKeys, [])
    }

    func testNonDigitHotkeysHaveNoAlias() throws {
        let url = try temporaryConfigURL(
            extension: "yaml",
            contents: """
            shortcuts:
              slack:
                hotkey: cmd+option+j
                bundle-id: com.tinyspeck.slackmacgap
            """
        )

        let configuration = try ConfigurationLoader.load(from: url)
        XCTAssertEqual(configuration.shortcuts.first?.aliasHotKeys, [])
    }

    func testKeypadHotkeyDoesNotAliasBackToTheTopRow() {
        let resolver = NumpadAliasResolver(claimedHotKeys: [])
        let keypad = try! KeyCombo.parse("cmd+option+numpad1")

        XCTAssertNil(resolver.alias(for: keypad))
    }

    func testAliasKeepsModifiers() {
        let resolver = NumpadAliasResolver(claimedHotKeys: [])
        let combo = try! KeyCombo.parse("cmd+ctrl+shift+7")
        let alias = resolver.alias(for: combo)

        XCTAssertEqual(alias?.normalizedValue, "cmd+ctrl+shift+numpad7")
        XCTAssertEqual(alias?.modifiers, combo.modifiers)
    }

    private func temporaryConfigURL(extension fileExtension: String, contents: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("config.\(fileExtension)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
