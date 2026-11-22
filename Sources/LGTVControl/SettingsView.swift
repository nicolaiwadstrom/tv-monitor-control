import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var controller: TVController
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.tvs) { tv in
                        Text(tv.name.isEmpty ? (tv.ip.isEmpty ? "New TV" : tv.ip) : tv.name).tag(tv.id)
                    }
                }
                Divider()
                HStack {
                    Button { addTV() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 180)

            Divider()

            if let idx = store.tvs.firstIndex(where: { $0.id == selection }) {
                TVEditor(tv: $store.tvs[idx], controller: controller)
                    .id(store.tvs[idx].id)
                    .padding(20)
            } else {
                Text("Add a TV with +, then pair it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { selection = selection ?? store.tvs.first?.id }
    }

    private func addTV() {
        var tv = TVConfig()
        tv.name = "LG TV \(store.tvs.count + 1)"
        store.tvs.append(tv)
        selection = tv.id
    }

    private func removeSelected() {
        guard let id = selection else { return }
        store.tvs.removeAll { $0.id == id }
        selection = store.tvs.first?.id
    }
}

private struct TVEditor: View {
    @Binding var tv: TVConfig
    @ObservedObject var controller: TVController

    private var inputChoices: [String] {
        var all = tv.knownInputs
        for i in ["HDMI_1", "HDMI_2", "HDMI_3", "HDMI_4"] where !all.contains(i) { all.append(i) }
        return all
    }

    var body: some View {
        Form {
            Toggle("Control this TV", isOn: $tv.enabled)
            TextField("Name", text: $tv.name)
            TextField("IP address", text: $tv.ip)

            HStack {
                TextField("MAC address", text: $tv.mac, prompt: Text("aa:bb:cc:dd:ee:ff"))
                Button("Detect") { Task { await controller.detectMAC(tv.id) } }
                    .disabled(tv.ip.isEmpty)
            }

            HStack {
                TextField("Input on wake", text: $tv.inputId, prompt: Text("HDMI_1"))
                Menu("Choose") {
                    ForEach(inputChoices, id: \.self) { input in
                        Button(input) { tv.inputId = input }
                    }
                }
                .fixedSize()
            }

            Picker("When screens turn off", selection: $tv.mode) {
                ForEach(PowerMode.allCases) { Text($0.label).tag($0) }
            }

            Picker("Keyboard volume keys", selection: $tv.volumeMode) {
                ForEach(VolumeMode.allCases) { Text($0.label).tag($0) }
            }
            if tv.volumeMode != .off {
                Text("Volume up/down/mute keys are sent to this TV instead of macOS. Needs Accessibility permission (System Settings → Privacy & Security → Accessibility). Keys held with ⌥/⇧/⌘/⌃ are left to macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(tv.clientKey == nil ? "Pair…" : "Re-pair / refresh inputs") {
                        Task { await controller.pair(tv.id) }
                    }
                    .disabled(tv.ip.isEmpty)
                    Button("Test off") { controller.set(tv.id, on: false) }
                        .disabled(tv.clientKey == nil)
                    Button("Test on") { controller.set(tv.id, on: true) }
                        .disabled(tv.clientKey == nil)
                }
                Text(tv.clientKey == nil ? "Not paired" : "Paired")
                    .font(.caption).foregroundStyle(.secondary)
                if !controller.status(tv.id).isEmpty {
                    Text(controller.status(tv.id)).font(.caption)
                }
            }

            Text("On the TV, enable Wake-on-LAN (Settings → General → Devices → External Devices → TV On With Mobile → Turn on via Wi-Fi; applies to Ethernet too). Screen-off mode keeps the TV reachable and wakes fastest.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
