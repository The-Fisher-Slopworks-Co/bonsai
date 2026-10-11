import Foundation

func L(_ key: String, _ args: any CVarArg...) -> String {
    L(key, bundle: .main, args)
}

func L(_ key: String, bundle: Bundle, _ args: [any CVarArg]) -> String {
    let format = bundle.localizedString(forKey: key, value: nil, table: nil)
    guard !args.isEmpty else { return format }
    let language =
        bundle.bundleURL.pathExtension == "lproj"
        ? bundle.bundleURL.deletingPathExtension().lastPathComponent
        : bundle.preferredLocalizations.first ?? "en"
    return withVaList(args) { NSString(format: format, locale: Locale(identifier: language), arguments: $0) as String }
}
