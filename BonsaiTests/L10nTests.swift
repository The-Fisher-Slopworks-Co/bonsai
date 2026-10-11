// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct L10nTests {
    func bundle(_ lang: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: lang, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func bothLanguagesPresent() throws {
        #expect(localized("connect.title", bundle: try bundle("en"), []) == "Connect to GitLab")
        #expect(localized("connect.title", bundle: try bundle("ru"), []) == "Подключение к GitLab")
    }

    @Test(arguments: [
        (1, "Отстаёт на 1 коммит"), (3, "Отстаёт на 3 коммита"), (5, "Отстаёт на 5 коммитов"),
        (21, "Отстаёт на 21 коммит"),
    ])
    func russianPlurals(n: Int, text: String) throws {
        #expect(localized("mr.behind", bundle: try bundle("ru"), [n]) == text)
    }

    @Test func englishPlurals() throws {
        let en = try bundle("en")
        #expect(localized("mr.behind", bundle: en, [1]) == "Behind by 1 commit")
        #expect(localized("mr.behind", bundle: en, [3]) == "Behind by 3 commits")
    }
}
