// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

func localized(_ key: String, _ args: any CVarArg...) -> String {
    localized(key, bundle: .main, args)
}

func localized(_ key: String, bundle: Bundle, _ args: [any CVarArg]) -> String {
    let format = bundle.localizedString(forKey: key, value: nil, table: nil)
    guard !args.isEmpty else { return format }
    let language =
        bundle.bundleURL.pathExtension == "lproj"
        ? bundle.bundleURL.deletingPathExtension().lastPathComponent
        : bundle.preferredLocalizations.first ?? "en"
    return withVaList(args) { NSString(format: format, locale: Locale(identifier: language), arguments: $0) as String }
}
