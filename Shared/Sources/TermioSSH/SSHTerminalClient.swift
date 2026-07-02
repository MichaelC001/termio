// Interactive SSH shell transport for the terminal surfaces: bytes in, bytes
// out, window-change on resize. The channel pattern follows madeye/gterm's
// proven swift-nio-ssh setup (MIT): one event loop per session, an ordered
// auth delegate (keys first, then password), PTY + shell requests fired from
// channelActive, and remote-half-closure enabled on the session channel.

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public struct SSHConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    /// Contents of an unencrypted OpenSSH ed25519 private key, if using key auth.
    public var privateKey: String?
    /// Sent in the PTY request. `xterm-256color` is Ghostty's own documented
    /// fallback for hosts without the ghostty terminfo — never send
    /// `xterm-ghostty` from a client app.
    public var term: String
    /// Optional remote command (e.g. `tmux new -A -s termio`). Empty → login shell.
    public var command: String?
    public var initialCols: Int
    public var initialRows: Int

    public init(
        host: String, port: Int = 22, username: String,
        password: String? = nil, privateKey: String? = nil,
        term: String = "xterm-256color", command: String? = nil,
        initialCols: Int = 80, initialRows: Int = 24
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.term = term
        self.command = command
        self.initialCols = initialCols
        self.initialRows = initialRows
    }
}

public enum SSHClientState {
    case idle
    case connecting
    case connected
    case failed(String)
    case closed
}

public final class SSHTerminalClient: @unchecked Sendable {
    private let config: SSHConfig
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var childChannel: Channel?
    private var ptyHandler: PTYChannelHandler?

    /// Remote bytes for the terminal. Fired on the SSH event loop — hop to
    /// your own queue if needed (libghostty's receive is thread-safe).
    public var onOutput: ((Data) -> Void)?
    /// State transitions, always delivered on the main queue.
    public var onState: ((SSHClientState) -> Void)?

    public init(config: SSHConfig) {
        self.config = config
    }

    public func start() {
        notify(.connecting)

        var offers: [NIOSSHUserAuthenticationOffer.Offer] = []
        if let keyText = config.privateKey {
            do {
                let key = try SSHKeyParser.parseED25519(openSSHPrivateKey: keyText)
                offers.append(.privateKey(.init(privateKey: key)))
            } catch {
                notify(.failed("Bad private key: \(error)"))
                return
            }
        }
        if let password = config.password, !password.isEmpty {
            offers.append(.password(.init(password: password)))
        }
        guard !offers.isEmpty else {
            notify(.failed("No authentication method configured"))
            return
        }

        let authDelegate = OrderedAuthDelegate(username: config.username, offers: offers)
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let handler = NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate: authDelegate,
                        serverAuthDelegate: AcceptAllHostKeys() // TODO: TOFU store before any release
                    )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandler(handler)
            }

        bootstrap.connect(host: config.host, port: config.port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let channel):
                self.channel = channel
                openShellChannel(on: channel)
            case .failure(let error):
                notify(.failed(Self.describe(error)))
            }
        }
    }

    private func openShellChannel(on channel: Channel) {
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sshHandler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { child, _ in
                    let pty = PTYChannelHandler(
                        term: self.config.term,
                        cols: self.config.initialCols,
                        rows: self.config.initialRows,
                        command: self.config.command,
                        onOutput: { [weak self] data in self?.onOutput?(data) },
                        onClose: { [weak self] error in
                            if let error {
                                self?.notify(.failed(Self.describe(error)))
                            } else {
                                self?.notify(.closed)
                            }
                        }
                    )
                    self.ptyHandler = pty
                    // Without remote-half-closure the server's EOF errors the
                    // channel instead of closing it cleanly.
                    return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        .flatMap { child.pipeline.addHandler(pty) }
                }
                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let child):
                        childChannel = child
                        notify(.connected)
                    case .failure(let error):
                        notify(.failed(Self.describe(error)))
                    }
                }
            case .failure(let error):
                notify(.failed(Self.describe(error)))
            }
        }
    }

    /// Keystrokes → remote. Callable from any thread (terminal IO thread
    /// included); hops to the channel's event loop.
    public func send(_ data: Data) {
        guard let childChannel else { return }
        var buffer = childChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        childChannel.eventLoop.execute {
            childChannel.writeAndFlush(buffer, promise: nil)
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard let childChannel, let ptyHandler else { return }
        childChannel.eventLoop.execute {
            ptyHandler.sendWindowChange(cols: cols, rows: rows)
        }
    }

    public func stop() {
        let child = childChannel
        let parent = channel
        childChannel = nil
        channel = nil
        ptyHandler = nil
        child?.close(promise: nil)
        parent?.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    private func notify(_ state: SSHClientState) {
        DispatchQueue.main.async { [onState] in
            onState?(state)
        }
    }

    /// `localizedDescription` on NIO errors is useless; interpolate instead.
    private static func describe(_ error: Error) -> String {
        "\(error)"
    }
}

// MARK: - Auth

/// Offers keys first, then password, consuming the next offer the server
/// actually advertises each time NIOSSH re-asks after a rejection. Succeeding
/// with `nil` ends the attempt cleanly instead of looping.
private final class OrderedAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var offers: [NIOSSHUserAuthenticationOffer.Offer]
    private var index = 0

    init(username: String, offers: [NIOSSHUserAuthenticationOffer.Offer]) {
        self.username = username
        self.offers = offers
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while index < offers.count {
            let offer = offers[index]
            index += 1
            let advertised: Bool = switch offer {
            case .privateKey: availableMethods.contains(.publicKey)
            case .password: availableMethods.contains(.password)
            default: false
            }
            if advertised {
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
                )
                return
            }
        }
        nextChallengePromise.succeed(nil)
    }
}

/// Prototype-only host key policy. Replace with a TOFU store (fingerprint
/// remembered per host:port, hard refusal on change) before shipping.
private final class AcceptAllHostKeys: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// MARK: - Channel handler

/// Requests a PTY then a shell (or exec) from `channelActive`, and shuttles
/// bytes both ways. Inbound stdout and stderr are both terminal output — the
/// remote PTY merges them anyway.
private final class PTYChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let term: String
    private let cols: Int
    private let rows: Int
    private let command: String?
    private let onOutput: (Data) -> Void
    private let onClose: (Error?) -> Void
    private var context: ChannelHandlerContext?

    init(
        term: String, cols: Int, rows: Int, command: String?,
        onOutput: @escaping (Data) -> Void,
        onClose: @escaping (Error?) -> Void
    ) {
        self.term = term
        self.cols = cols
        self.rows = rows
        self.command = command
        self.onOutput = onOutput
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([.ECHO: 1, .ICANON: 1, .ISIG: 1])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        if let command, !command.isEmpty {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                promise: nil
            )
        } else {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ShellRequest(wantReply: true),
                promise: nil
            )
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes)
        else { return }
        onOutput(Data(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClose(error)
        context.close(promise: nil)
    }

    /// Must run on the event loop.
    func sendWindowChange(cols: Int, rows: Int) {
        guard let context else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        context.triggerUserOutboundEvent(event, promise: nil)
    }
}
