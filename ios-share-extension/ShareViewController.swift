import UIKit
import Social
import MobileCoreServices
import UniformTypeIdentifiers

@objc(ShareViewController)
@objcMembers
class ShareViewController: UIViewController {

    private let accentColor = UIColor(red: 0.94, green: 0.27, blue: 0.34, alpha: 1.0)
    
    private lazy var containerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()
    
    private lazy var blurView: UIVisualEffectView = {
        let blur = UIBlurEffect(style: .systemMaterial)
        let view = UIVisualEffectView(effect: blur)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 20
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }()
    
    private lazy var iconImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = accentColor
        
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        imageView.image = UIImage(systemName: "arrow.down.circle.fill", withConfiguration: config)
        return imageView
    }()
    
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "PodcastThis"
        label.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        label.textColor = .label
        label.textAlignment = .center
        return label
    }()
    
    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Extracting link…"
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()
    
    private lazy var spinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.color = accentColor
        return spinner
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        processSharedItems()
    }

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        view.addSubview(containerView)
        containerView.addSubview(blurView)
        
        let contentStack = UIStackView(arrangedSubviews: [iconImageView, titleLabel, statusLabel, spinner])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .center
        contentStack.spacing = 10
        
        blurView.contentView.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 240),
            
            blurView.topAnchor.constraint(equalTo: containerView.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            
            contentStack.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -24),
            
            iconImageView.heightAnchor.constraint(equalToConstant: 48),
            iconImageView.widthAnchor.constraint(equalToConstant: 48)
        ])
        
        spinner.startAnimating()
        
        containerView.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        containerView.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: .curveEaseOut) {
            self.containerView.transform = .identity
            self.containerView.alpha = 1.0
        }
    }

    private func processSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem], !extensionItems.isEmpty else {
            finishWithError("No content received")
            return
        }

        var foundProvider: NSItemProvider?
        var requestedType: String?

        let typeCandidates = [
            "public.url",
            "public.plain-text",
            "public.utf8-plain-text",
            "public.text",
            "com.apple.property-list"
        ]

        outerLoop: for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for type in typeCandidates {
                for provider in attachments {
                    if provider.hasItemConformingToTypeIdentifier(type) {
                        foundProvider = provider
                        requestedType = type
                        break outerLoop
                    }
                }
            }
        }

        guard let provider = foundProvider, let type = requestedType else {
            finishWithError("No link found")
            return
        }

        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.finishWithError(error.localizedDescription)
                }
                return
            }

            var detectedString: String?
            if let url = item as? URL {
                detectedString = url.absoluteString
            } else if let nsUrl = item as? NSURL {
                detectedString = nsUrl.absoluteString
            } else if let text = item as? String {
                detectedString = text
            } else if let nsString = item as? NSString {
                detectedString = nsString as String
            } else if let dict = item as? NSDictionary {
                if let urlStr = dict["URL"] as? String ?? dict["url"] as? String ?? dict["href"] as? String {
                    detectedString = urlStr
                } else if let jsResults = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary,
                          let urlStr = jsResults["URL"] as? String ?? jsResults["url"] as? String ?? jsResults["href"] as? String {
                    detectedString = urlStr
                }
            }

            DispatchQueue.main.async {
                guard let raw = detectedString, let validURL = self.extractValidUrl(from: raw) else {
                    self.finishWithError("No valid URL found")
                    return
                }
                self.forwardToApp(url: validURL)
            }
        }
    }

    private func extractValidUrl(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") {
            return trimmed
        }
        
        // Regex / DataDetector search for URLs in shared text block
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        
        if let firstMatch = matches?.first, let range = Range(firstMatch.range, in: text) {
            return String(text[range])
        }
        
        if trimmed.hasPrefix("www.") || trimmed.hasPrefix("youtu.be/") || trimmed.hasPrefix("youtube.com/") {
            return "https://" + trimmed
        }
        
        return nil
    }

    private func savePendingShare(url: String) {
        let baseDirPath: String
        #if targetEnvironment(simulator)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDirPath = appSupport.appendingPathComponent("PodcastThis").path
        #else
        if FileManager.default.fileExists(atPath: "/var/mobile/Library/Application Support") {
            baseDirPath = "/var/mobile/Library/Application Support/PodcastThis"
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            baseDirPath = appSupport.appendingPathComponent("PodcastThis").path
        }
        #endif

        let baseDirURL = URL(fileURLWithPath: baseDirPath)
        try? FileManager.default.createDirectory(at: baseDirURL, withIntermediateDirectories: true, attributes: nil)

        let fileURL = baseDirURL.appendingPathComponent("pending_shares.json")
        let payload: [String: Any] = [
            "url": url,
            "timestamp": Date().timeIntervalSince1970,
            "action": "download"
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: fileURL)
            let cPath = fileURL.path.cString(using: .utf8)
            if let cPath = cPath {
                chmod(cPath, 0o666)
            }
        }
    }

    private func forwardToApp(url: String) {
        statusLabel.text = "Opening PodcastThis…"
        spinner.stopAnimating()
        
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        iconImageView.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: config)
        iconImageView.tintColor = .systemGreen
        
        // 1. Always persist to pending_shares queue file first
        savePendingShare(url: url)
        
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let deepLinkURL = URL(string: "podcastthis://add?url=\(encoded)") else {
            finishWithError("Failed to create link")
            return
        }

        // 2. Open the main application
        openURL(deepLinkURL) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }

    private func openURL(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        // Strategy 1: LSApplicationWorkspace (LaunchServices) - openSensitiveURL:withOptions: & openURL:
        if openURLViaWorkspace(url) {
            completion?(true)
            return
        }

        // Strategy 2: posix_spawn uiopen tool
        if openURLViaUIOpen(url) {
            completion?(true)
            return
        }

        // Strategy 3: LSApplicationWorkspace openApplicationWithBundleID
        if openAppByBundleID("com.saihgupr.podcastthis") {
            completion?(true)
            return
        }

        // Strategy 4: Fallback NSExtensionContext openURL
        let selector = NSSelectorFromString("openURL:completionHandler:")
        if let context = self.extensionContext, context.responds(to: selector) {
            typealias OpenURLMethod = @convention(c) (NSObject, Selector, NSURL, ((Bool) -> Void)?) -> Void
            let method = class_getMethodImplementation(type(of: context), selector)
            let callable = unsafeBitCast(method, to: OpenURLMethod.self)
            callable(context, selector, url as NSURL, completion)
            return
        }

        // Strategy 5: Responder chain search for UIApplication
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:], completionHandler: completion)
                return
            }
            responder = responder?.next
        }

        completion?(false)
    }

    @discardableResult
    private func openURLViaWorkspace(_ url: URL) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }
        let defaultWorkspaceSelector = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultWorkspaceSelector),
              let workspace = workspaceClass.perform(defaultWorkspaceSelector)?.takeUnretainedValue() else {
            return false
        }
        
        let sensitiveSelector = NSSelectorFromString("openSensitiveURL:withOptions:")
        if workspace.responds(to: sensitiveSelector) {
            let method = class_getMethodImplementation(type(of: workspace), sensitiveSelector)
            typealias SensitiveFunc = @convention(c) (AnyObject, Selector, NSURL, NSDictionary?) -> Bool
            let function = unsafeBitCast(method, to: SensitiveFunc.self)
            let success = function(workspace, sensitiveSelector, url as NSURL, nil)
            if success { return true }
        }
        
        let openSelector = NSSelectorFromString("openURL:")
        if workspace.responds(to: openSelector) {
            let method = class_getMethodImplementation(type(of: workspace), openSelector)
            typealias OpenFunc = @convention(c) (AnyObject, Selector, NSURL) -> Bool
            let function = unsafeBitCast(method, to: OpenFunc.self)
            let success = function(workspace, openSelector, url as NSURL)
            if success { return true }
        }
        
        return false
    }

    @discardableResult
    private func openURLViaUIOpen(_ url: URL) -> Bool {
        let candidates = ["/var/jb/usr/bin/uiopen", "/usr/bin/uiopen", "/var/jb/usr/local/bin/uiopen"]
        guard let binary = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return false
        }
        var pid: pid_t = 0
        let args = [binary, url.absoluteString]
        let cArgs = args.map { strdup($0) } + [nil]
        defer { for ptr in cArgs { if let p = ptr { free(p) } } }
        
        let spawnStatus = posix_spawn(&pid, binary, nil, nil, cArgs, nil)
        if spawnStatus == 0 {
            var exitStatus: Int32 = 0
            waitpid(pid, &exitStatus, 0)
            return exitStatus == 0
        }
        return false
    }

    @discardableResult
    private func openAppByBundleID(_ bundleID: String) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }
        let defaultWorkspaceSelector = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultWorkspaceSelector),
              let workspace = workspaceClass.perform(defaultWorkspaceSelector)?.takeUnretainedValue() else {
            return false
        }
        let openAppSelector = NSSelectorFromString("openApplicationWithBundleID:")
        if workspace.responds(to: openAppSelector) {
            let method = class_getMethodImplementation(type(of: workspace), openAppSelector)
            typealias OpenAppFunc = @convention(c) (AnyObject, Selector, NSString) -> Bool
            let function = unsafeBitCast(method, to: OpenAppFunc.self)
            return function(workspace, openAppSelector, bundleID as NSString)
        }
        return false
    }

    private func finishWithError(_ message: String) {
        spinner.stopAnimating()
        statusLabel.text = message
        iconImageView.image = UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))
        iconImageView.tintColor = .systemRed
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "PodcastThisShare", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }
}

