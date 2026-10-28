import UIKit
import WebKit
import ObjectiveC

/// Removes the prev/next/Done bar above the keyboard by swapping WKContentView for a
/// runtime subclass whose inputAccessoryView is nil. No-op if WKContentView isn't found.
/// QuickType suggestions (contacts etc.) are part of the keyboard and are FE's job (autocomplete attrs).
enum KeyboardAccessoryRemover {
    private static let subclassName = "EveNoAccessoryContentView"

    static func apply(to webView: WKWebView) {
        guard let content = webView.scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContentView")
        }) else { return }
        let base: AnyClass = type(of: content)
        let sub: AnyClass
        if let existing = NSClassFromString(subclassName) {
            sub = existing
        } else {
            guard let created = objc_allocateClassPair(base, subclassName, 0) else { return }
            let block: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
            let imp = imp_implementationWithBlock(block)
            let sel = #selector(getter: UIResponder.inputAccessoryView)
            guard let method = class_getInstanceMethod(UIView.self, sel) else { return }
            class_addMethod(created, sel, imp, method_getTypeEncoding(method))
            objc_registerClassPair(created)
            sub = created
        }
        object_setClass(content, sub)
    }
}
