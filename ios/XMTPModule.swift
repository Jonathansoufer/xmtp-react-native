import ExpoModulesCore
import XMTP

class ReactNativeSigner: NSObject, XMTP.SigningKey {
    enum Error: Swift.Error {
        case invalidSignature
    }

    var module: XMTPModule
    var address: String
    var continuations: [String: CheckedContinuation<XMTP.Signature, Swift.Error>] = [:]

    init(module: XMTPModule, address: String) {
        self.module = module
        self.address = address
    }

    func handle(id: String, signature: String) throws {
        guard let continuation = continuations[id] else {
            return
        }

        guard let signatureData = Data(base64Encoded: Data(signature.utf8)), signatureData.count == 65 else {
            continuation.resume(throwing: Error.invalidSignature)
            continuations.removeValue(forKey: id)
            return
        }

        let signature = XMTP.Signature.with {
            $0.ecdsaCompact.bytes = signatureData[0 ..< 64]
            $0.ecdsaCompact.recovery = UInt32(signatureData[64])
        }

        continuation.resume(returning: signature)
        continuations.removeValue(forKey: id)
    }

    func sign(_ data: Data) async throws -> XMTP.Signature {
        let request = SignatureRequest(message: String(data: data, encoding: .utf8)!)

        module.sendEvent("sign", [
            "id": request.id,
            "message": request.message
        ])

        return try await withCheckedThrowingContinuation { continuation in
            continuations[request.id] = continuation
        }
    }

    func sign(message: String) async throws -> XMTP.Signature {
        return try await sign(Data(message.utf8))
    }
}

struct SignatureRequest: Codable {
    var id = UUID().uuidString
    var message: String
}

extension Conversation {

    static func cacheKeyForTopic(clientAddress: String, topic: String) -> String {
            return "\(clientAddress):\(topic)"
        }

    func cacheKey(_ clientAddress: String) -> String {
        return Conversation.cacheKeyForTopic(clientAddress: clientAddress, topic: topic)
    }
}

public class XMTPModule: Module {
    var apiEnvironments = [
        "local": XMTP.ClientOptions.Api(
            env: XMTP.XMTPEnvironment.local,
            isSecure: false
        ),
        "dev": XMTP.ClientOptions.Api(
            env: XMTP.XMTPEnvironment.dev,
            isSecure: true
        ),
        "production": XMTP.ClientOptions.Api(
            env: XMTP.XMTPEnvironment.production,
            isSecure: true
        ),
    ]

    var clients: [String: XMTP.Client] = [:]
    var signer: ReactNativeSigner?
    var conversations: [String: Conversation] = [:]
    var subscriptions: [String: Task<Void, Never>] = [:]

    enum Error: Swift.Error {
        case noClient, conversationNotFound(String), noMessage
    }

    public func definition() -> ModuleDefinition {
    Name("XMTP")

    Events("sign", "authed", "conversation", "message")

        Function("address") { (clientAddress: String) -> String in
            if let client = clients[clientAddress] {
                    return client.address
                } else {
                    return "No Client."
                }
        }

        //
        // Auth functions
        //
        AsyncFunction("auth") { (address: String, environment: String) in
                let signer = ReactNativeSigner(module: self, address: address)
                self.signer = signer
                let options = XMTP.ClientOptions(api: apiEnvironments[environment] ?? apiEnvironments["local"]!)
                self.clients[address] = try await XMTP.Client.create(account: signer, options: options)
                self.signer = nil
                sendEvent("authed")
        }

        Function("receiveSignature") { (requestID: String, signature: String) in
            try signer?.handle(id: requestID, signature: signature)
        }

        // Generate a random wallet and set the client to that
        AsyncFunction("createRandom") { (environment: String) -> String in
            let privateKey = try PrivateKey.generate()
            let options = XMTP.ClientOptions(api: apiEnvironments[environment] ?? apiEnvironments["dev"]!)
            let client = try await Client.create(account: privateKey, options: options)

            self.clients[client.address] = client
            return client.address
        }

        // Create a client using its serialized key bundle.
        AsyncFunction("createFromKeyBundle") { (keyBundle: String, environment: String) -> String in
            let bundle = try PrivateKeyBundle(serializedData: Data(base64Encoded: Data(keyBundle.utf8))!)
            let options = XMTP.ClientOptions(api: apiEnvironments[environment] ?? apiEnvironments["dev"]!)
            let client = try await Client.from(bundle: bundle, options: options)
            self.clients[client.address] = client
            return client.address
        }

        // Export the client's serialized key bundle.
        AsyncFunction("exportKeyBundle") { (clientAddress: String) -> String in
            guard let client = clients[clientAddress] else {
                throw Error.noClient
            }
            let bundle = try client.privateKeyBundle.serializedData().base64EncodedString()
            return bundle
        }

        // Export the conversation's serialized topic data.
        AsyncFunction("exportConversationTopicData") { (clientAddress: String, topic: String) -> String in
            guard let client = clients[clientAddress] else {
                throw Error.noClient
            }
            guard let conversation = try await findConversation(clientAddress: clientAddress, topic: topic) else {
                throw Error.conversationNotFound(topic)
            }
            return try conversation.toTopicData().serializedData().base64EncodedString()
        }

        // Import a conversation from its serialized topic data.
        AsyncFunction("importConversationTopicData") { (clientAddress: String, topicData: String) -> String in
            guard let client = clients[clientAddress] else {
                throw Error.noClient
            }
            let data = try Xmtp_KeystoreApi_V1_TopicMap.TopicData(
                serializedData: Data(base64Encoded: Data(topicData.utf8))!
            )
            let conversation = client.conversations.importTopicData(data: data)
            conversations[conversation.cacheKey(clientAddress)] = conversation
            return try ConversationWrapper.encode(ConversationWithClientAddress(client: client, conversation: conversation))
        }

        //
        // Client API
        AsyncFunction("canMessage") { (clientAddress: String, peerAddress: String) -> Bool in
            guard let client = clients[clientAddress] else {
                throw Error.noClient
            }

            return try await client.canMessage(peerAddress)
        }

        AsyncFunction("listConversations") { (clientAddress: String) -> [String] in
            guard let client = clients[clientAddress] else {
                throw Error.noClient
            }

            let conversations = try await client.conversations.list()

            return try conversations.map { conversation in
                self.conversations[conversation.cacheKey(clientAddress)] = conversation

                return try ConversationWrapper.encode(ConversationWithClientAddress(client: client, conversation: conversation))
            }
        }

        AsyncFunction("loadMessages") { (clientAddress: String, topics: [String], conversationIDs: [String?], limit: Int?, before: Double?, after: Double?) -> [[UInt8]] in
            let beforeDate = before != nil ? Date(timeIntervalSince1970: before!) : nil
            let afterDate = after != nil ? Date(timeIntervalSince1970: after!) : nil     
            guard let client = clients[clientAddress] else {
                throw Error.noClient
            }
            
            let decodedMessages = try await client.conversations.listBatchMessages(
                topics: topics,
                    limit: limit,
                    before: beforeDate,
                after: afterDate)

            let messages = try decodedMessages.map { (msg) in try EncodedMessageWrapper.encode(msg) }

            return messages
        }

        AsyncFunction("sendEncodedContentData") { (clientAddress: String, conversationTopic: String, conversationID: String?, content: Array<UInt8>) -> String in
            guard let conversation = try await findConversation(clientAddress: clientAddress, topic: conversationTopic) else {
                throw Error.conversationNotFound("no conversation found for \(conversationTopic)")
            }
            
            let contentData = Data(content)
            let encodedContent = try EncodedContent(serializedData: contentData)

            let messageID = try await conversation.send(encodedContent: encodedContent)
            return messageID
        }

        AsyncFunction("createConversation") { (clientAddress: String, peerAddress: String, conversationID: String?) -> String in
            guard let client = clients[clientAddress] else {
                throw Error.noClient
            }

            do {
                let conversation = try await client.conversations.newConversation(with: peerAddress, context: .init(
                    conversationID: conversationID ?? ""
                ))

                return try ConversationWrapper.encode(ConversationWithClientAddress(client: client, conversation: conversation))
            } catch {
                print("ERRRO!: \(error.localizedDescription)")
                throw error
            }
        }

        Function("subscribeToConversations") { (clientAddress: String) in
            subscribeToConversations(clientAddress: clientAddress)
        }

        Function("subscribeToAllMessages") { (clientAddress: String) in
            subscribeToAllMessages(clientAddress: clientAddress)
        }

        AsyncFunction("subscribeToMessages") { (clientAddress: String, topic: String, conversationID: String?) in
            try await subscribeToMessages(clientAddress: clientAddress, topic: topic, conversationID: conversationID)
        }

        AsyncFunction("unsubscribeFromMessages") { (clientAddress: String, topic: String, conversationID: String?) in
            try await unsubscribeFromMessages(clientAddress: clientAddress, topic: topic, conversationID: conversationID)
        }

        AsyncFunction("registerPushToken") { (pushServer: String, token: String) in
            XMTPPush.shared.setPushServer(pushServer)
            do {
                try await XMTPPush.shared.register(token: token)
            } catch {
                print("Error registering: \(error)")
            }
        }

        AsyncFunction("subscribePushTopics") { (topics: [String]) in
            do {
                try await XMTPPush.shared.subscribe(topics: topics)
            } catch {
                print("Error subscribing: \(error)")
            }
        }

        AsyncFunction("decodeMessage") { (clientAddress: String, topic: String, encryptedMessage: String, conversationID: String?) -> String in
            guard let encryptedMessageData = Data(base64Encoded: Data(encryptedMessage.utf8))else {
                throw Error.noMessage
            }

            let envelope = XMTP.Envelope.with { envelope in
                envelope.message = encryptedMessageData
                envelope.contentTopic = topic
            }

            guard let conversation = try await findConversation(clientAddress: clientAddress, topic: topic) else {
                throw Error.conversationNotFound("no conversation found for \(topic)")
            }
            let decodedMessage = try conversation.decode(envelope)
            return try DecodedMessageWrapper.encode(decodedMessage)
        }
  }

    //
    // Helpers
    //

    func findConversation(clientAddress: String, topic: String) async throws -> Conversation? {
        guard let client = clients[clientAddress] else {
            throw Error.noClient
        }

        let cacheKey = Conversation.cacheKeyForTopic(clientAddress: clientAddress, topic: topic)
        if let conversation = conversations[cacheKey] {
            return conversation
        } else if let conversation = try await client.conversations.list().first(where: { $0.topic == topic }) {
            conversations[cacheKey] = conversation
            return conversation
        }

        return nil
    }

    func subscribeToConversations(clientAddress: String) {
        guard let client = clients[clientAddress] else {
            return
        }

        subscriptions["conversations"] = Task {
            do {
                for try await conversation in client.conversations.stream() {
                    sendEvent("conversation", [
                        "topic": conversation.topic,
                        "peerAddress": conversation.peerAddress,
                        "version": conversation.version == .v1 ? "v1" : "v2",
                        "conversationID": conversation.conversationID
                    ])
                }
            } catch {
                print("Error in conversations subscription: \(error)")
                subscriptions["conversations"]?.cancel()
            }
        }
    }

    func subscribeToAllMessages(clientAddress: String) {
        guard let client = clients[clientAddress] else {
            return
        }

        subscriptions["messages"] = Task {
            do {
                for try await message in try await client.conversations.streamAllMessages() {
                    sendEvent("message", [
                        "id": message.id,
                        "content": (try? message.content()) ?? message.fallbackContent,
                        "senderAddress": message.senderAddress,
                        "sent": message.sent
                    ])
                }
            } catch {
                print("Error in all messages subscription: \(error)")
                subscriptions["messages"]?.cancel()
            }
        }
    }

    func subscribeToMessages(clientAddress: String, topic: String, conversationID: String?) async throws {
        guard let conversation = try await findConversation(clientAddress: clientAddress, topic: topic) else {
            return
        }

        subscriptions[conversation.cacheKey(clientAddress)] = Task {
            do {
                for try await message in conversation.streamMessages() {
                    sendEvent("message", [
                        "topic": conversation.topic,
                        "conversationID": conversation.conversationID,
                        "messageJSON": try DecodedMessageWrapper.encode(message)
                    ])
                }
            } catch {
                print("Error in messages subscription: \(error)")
                subscriptions[conversation.cacheKey(clientAddress)]?.cancel()
            }
        }
    }

    func unsubscribeFromMessages(clientAddress: String, topic: String, conversationID: String?) async throws {
        guard let conversation = try await findConversation(clientAddress: clientAddress, topic: topic) else {
            return
        }

        subscriptions[conversation.cacheKey(clientAddress)]?.cancel()
    }
}
