import re
with open('Sources/Companion/CompanionServer.swift', 'r') as f:
    content = f.read()
    
new_content = content.replace(
    '''                    viewHandler: { [weak self] req in
                        self?.onRemoteViewUpdate?(req) ?? (status: 500, body: Data("{}".utf8))
                    }''',
    '''                    viewHandler: { [weak self] req in
                        self?.onRemoteViewUpdate?(req) ?? (status: 500, body: Data("{}".utf8))
                    },
                    pairHandler: { [weak self] deviceName in
                        self?.onRemotePair?(deviceName) ?? (status: 403, body: Data("{}".utf8))
                    }'''
)
with open('Sources/Companion/CompanionServer.swift', 'w') as f:
    f.write(new_content)
