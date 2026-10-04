import re
with open('ios/Sources/CompanionViews.swift', 'r') as f:
    content = f.read()

new_content = content.replace(
    '''                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Forget Mac") { model.forget() }
                        }''',
    '''                        ToolbarItem(placement: .topBarTrailing) {
                            Button { model.showForgetConfirm = true } label: {
                                Image(systemName: "link.badge.minus")
                            }
                        }'''
)

new_content = new_content.replace(
    '''    @State private var showAddPathAlert = false''',
    '''    @State private var showAddPathAlert = false\n    @State private var showForgetConfirm = false'''
)

new_content = new_content.replace(
    '''        .sheet(isPresented: codePresented) {''',
    '''        .alert("Forget Mac?", isPresented: $model.showForgetConfirm) {
            Button("Forget", role: .destructive) { model.forget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to forget this Mac?")
        }
        .sheet(isPresented: codePresented) {'''
)

new_content = new_content.replace(
    '''Image(systemName: row.isApp ? "app.fill" : "gearshape")''',
    '''Image(systemName: row.isApp ? "app.fill" : "cpu")'''
)

with open('ios/Sources/CompanionViews.swift', 'w') as f:
    f.write(new_content)
