import re
with open('ios/Sources/CompanionModel.swift', 'r') as f:
    content = f.read()

new_content = content.replace(
    '''        isConnectingRemote = true
        remoteConnectError = nil
        defer { isConnectingRemote = false }

        var finalToken = remoteTokenDraft.uppercased().filter { CompanionToken.alphabet.contains($0) }
        if finalToken.isEmpty {
            // Request pairing
            do {
                // We need a simple HTTP request to GET or POST /v1/pair
                // ...
            }
        }''',
    r'''        isConnectingRemote = true
        remoteConnectError = nil
        defer { isConnectingRemote = false }

        let finalToken = remoteTokenDraft.uppercased().filter { CompanionToken.alphabet.contains($0) }
        
        do {
            let actualToken: String
            if finalToken.isEmpty {
                #if os(iOS)
                let deviceName = await UIDevice.current.name
                #else
                let deviceName = "Unknown Device"
                #endif
                actualToken = try await CompanionConnection.requestPair(endpoint: .hostPort(host: .init(host), port: nwPort), deviceName: deviceName)
            } else {
                actualToken = finalToken
            }
            
            let next = try await Self.fetch(endpoint: .hostPort(host: .init(host), port: nwPort), token: actualToken)
            let name = remoteNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            saved = SavedMac(
                peerID: "remote-\(host)-\(portNum)",
                name: name.isEmpty ? next.hostName : name,
                token: actualToken,
                remoteHost: host,
                remotePort: portNum
            )
            persistSaved()
            snapshot = next
            phase = .live
        } catch CompanionClientError.unauthorized {
            remoteConnectError = "Pairing denied or invalid code."
        } catch {
            remoteConnectError = "Could not connect to \(host):\(portNum)."
        }'''
)
with open('ios/Sources/CompanionModel.swift', 'w') as f:
    f.write(new_content)
