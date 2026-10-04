import re
with open('Sources/Store/HogStore.swift', 'r') as f:
    content = f.read()

new_content = content.replace(
    '''        companionServer.onRemoteViewUpdate = { [weak self] req in
            guard let self else {
                return (500, Data("{\\"error\\": \\"Store unavailable\\"}".utf8))
            }
            return self.performRemoteViewUpdate(req)
        }''',
    '''        companionServer.onRemoteViewUpdate = { [weak self] req in
            guard let self else {
                return (500, Data("{\\"error\\": \\"Store unavailable\\"}".utf8))
            }
            return self.performRemoteViewUpdate(req)
        }
        
        companionServer.onRemotePair = { [weak self] deviceName in
            guard let self = self else {
                return (500, Data())
            }
            var approved = false
            let sema = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Pair Request"
                alert.informativeText = "\\(deviceName) wants to connect to Hog Hunter. Allow?"
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Deny")
                if alert.runModal() == .alertFirstButtonReturn {
                    approved = true
                }
                sema.signal()
            }
            sema.wait()
            if approved {
                let json = "{\\"token\\":\\"\\(self.pairingToken)\\"}"
                return (200, Data(json.utf8))
            } else {
                return (403, Data("{\\"error\\":\\"Denied\\"}".utf8))
            }
        }'''
)
with open('Sources/Store/HogStore.swift', 'w') as f:
    f.write(new_content)
