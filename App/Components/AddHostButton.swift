import AeroTheme
import SwiftUI

/// The primary "Add Host" call to action. Opens the main window's host editor sheet.
struct AddHostButton: View {
    @Environment(AppModel.self) private var model
    var title = "Add Host"

    var body: some View {
        Button(title, systemImage: "plus") { model.requestNewHost() }
            .buttonStyle(.aqua)
    }
}
