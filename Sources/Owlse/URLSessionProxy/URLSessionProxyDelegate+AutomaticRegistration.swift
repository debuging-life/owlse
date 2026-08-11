// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import Foundation

extension URLSessionProxyDelegate {
    /// Enables automatic logging and remote debugging of network requests using
    /// `URLSessionProxyDelegate`.
    ///
    /// - note: This method works by swizzling `URLSession` init and adding
    /// `URLSessionProxyDelegate` to the delegate chain and adding
    /// `RemoteLoggerURLProtocol` to the list of session protocol classes.
    ///
    /// - warning: This logging method works only with delegate-based `URLSession`
    /// instances.
    ///
    /// - parameter logger: The network logger to be used for recording the requests. By default, uses shared logger.
    ///
    /// - warning: This method is soft-deprecated in Owlse 5.0.
    public static func enableAutomaticRegistration(logger: NetworkLogger? = nil) {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { _enableAutomaticRegistration(logger: logger) }
        }
        MainActor.assumeIsolated {
            _enableAutomaticRegistration(logger: logger)
        }
    }

    @MainActor
    static func _enableAutomaticRegistration(logger: NetworkLogger?) {
        guard !isAutomaticNetworkLoggingEnabled else { return }

        sharedNetworkLogger = logger
        if let lhs = class_getClassMethod(URLSession.self, #selector(URLSession.init(configuration:delegate:delegateQueue:))),
           let rhs = class_getClassMethod(URLSession.self, #selector(URLSession.owlse_init(configuration:delegate:delegateQueue:))) {
            method_exchangeImplementations(lhs, rhs)
        }
    }
}

/// Returns `true` if automatic logging was already enabled using one of the
/// existing mechanisms provided by Owlse.
@MainActor
var isAutomaticNetworkLoggingEnabled: Bool {
    guard sharedNetworkLogger == nil else {
        NSLog("Error: Owlse network request logging is already enabled")
        return true
    }
    return false
}

func isConfiguringSessionSafe(delegate: URLSessionDelegate?) -> Bool {
    guard let delegate else { return true }
    let className = NSStringFromClass(type(of: delegate))
    if className.contains("GTMSessionFetcher") {
        return false
    }
    return true
}

private var sharedNetworkLogger: NetworkLogger? {
    get { _sharedLogger.value }
    set { _sharedLogger.value = newValue }
}
private let _sharedLogger = Mutex<NetworkLogger?>(nil)

private extension URLSession {
    @objc class func owlse_init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate?, delegateQueue: OperationQueue?) -> URLSession {
        guard isConfiguringSessionSafe(delegate: delegate) else {
            return self.owlse_init(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        }
        configuration.protocolClasses = [MockingURLProtocol.self] + (configuration.protocolClasses ?? [])
        let delegate = URLSessionProxyDelegate(logger: sharedNetworkLogger, delegate: delegate)
        return self.owlse_init(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }
}

// MARK: - Experimental (Deprecated)

@available(*, deprecated, message: "Experimental.URLSessionProxy is replaced with NetworkLogger.enableProxy() from the OwlseProxy target")
public enum Experimental {}

@available(*, deprecated, message: "Experimental.URLSessionProxy is replaced with NetworkLogger.enableProxy() from the OwlseProxy target")
public extension Experimental {
    @MainActor
    final class URLSessionProxy {
        public static let shared = URLSessionProxy()
        public var logger: NetworkLogger = .init()
        public var configuration: URLSessionConfiguration = .default
        public var ignoredHosts = Set<String>()

        public var isEnabled: Bool = false {
            didSet {
                NSLog("Owlse.URLSessionProxu can't be disabled at runtime")
            }
        }
    }
}
