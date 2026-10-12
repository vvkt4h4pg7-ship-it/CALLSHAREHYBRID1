import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        TabView {
            PhoneView()
                .tabItem { Label("Phone", systemImage: "phone.fill") }
            RecentsView()
                .tabItem { Label("Recents", systemImage: "clock") }
            ContactsView()
                .tabItem { Label("Contacts", systemImage: "person.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.green)
        .onAppear { app.start() }
    }
}

struct PhoneView: View {
    @EnvironmentObject var app: AppModel

    private let buttons = ["1","2","3","4","5","6","7","8","9","*","0","#"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    numberDisplay
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(buttons, id: \.self) { button in
                            Button(button) { app.tapDialpad(button) }
                                .font(.system(size: 30, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .frame(height: 64)
                                .background(.thinMaterial, in: Circle())
                        }
                    }
                    actionRow
                }
                .padding()
            }
            .navigationTitle("J7Bridge")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(app.bleStatus, systemImage: app.bleStatus == "Connected" ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                Spacer()
                Text(app.deviceName).foregroundStyle(.secondary)
            }
            HStack {
                Label("Wi-Fi Audio", systemImage: "wifi")
                Spacer()
                Text(app.voiceStatus).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Text("Call").bold()
                Spacer()
                Text(app.callStatus)
            }
            if !app.callerName.isEmpty {
                HStack {
                    Text("Caller").bold()
                    Spacer()
                    Text(app.callerName)
                }
            }
            HStack {
                Text("Voice").bold()
                Spacer()
                Text(app.voiceStatus)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var numberDisplay: some View {
        let display: String
        if app.callStatus == "ACTIVE" {
            display = app.callerName.isEmpty ? app.number : app.callerName
        } else if app.callStatus == "DIALING" || app.callStatus == "RINGING" {
            display = app.callerName.isEmpty ? app.number : app.callerName
        } else {
            display = app.dialString.isEmpty ? "Enter number" : app.dialString
        }

        return HStack {
            Text(display)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer()
            if !app.dialString.isEmpty && app.callStatus == "IDLE" {
                Button { app.backspaceDialpad() } label: { Image(systemName: "delete.left") }
            }
        }
        .padding(.horizontal, 8)
    }

    private var actionRow: some View {
        HStack(spacing: 18) {
            if app.callStatus == "ACTIVE" || app.callStatus == "DIALING" || app.callStatus == "RINGING" {
                Button(role: .destructive) { app.endCall() } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .frame(width: 74, height: 58)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { app.makeCall() } label: {
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .frame(width: 74, height: 58)
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.dialString.isEmpty || app.bleStatus != "Connected")
            }
        }
    }
}

struct RecentsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationStack {
            List {
                if app.history.records.isEmpty {
                    EmptyStateView(title: "No Calls", systemImage: "clock", message: "J7Bridge call history will appear here.")
                } else {
                    ForEach(app.history.records) { record in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: record.direction))
                                .foregroundStyle(record.direction == .missed ? .red : .green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name ?? record.number).font(.headline)
                                if let name = record.name { Text(record.number).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(record.date, style: .time).font(.caption)
                                Text(record.direction.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button { app.dialString = record.number } label: {
                                Label("Dial", systemImage: "phone.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recents")
            .toolbar {
                if !app.history.records.isEmpty {
                    Button("Clear") { app.clearHistory() }
                }
            }
        }
    }

    private func icon(for direction: CallDirection) -> String {
        switch direction {
        case .incoming: return "phone.arrow.down.left"
        case .outgoing: return "phone.arrow.up.right"
        case .missed: return "phone.arrow.down.left"
        }
    }
}

struct ContactsView: View {
    @EnvironmentObject var app: AppModel
    @State private var search = ""
    @State private var showAdd = false

    var filtered: [AppContact] {
        guard !search.isEmpty else { return app.contacts.contacts }
        return app.contacts.contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.phones.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.contacts.authorization != .authorized {
                    EmptyStateView(title: "Contacts Access", systemImage: "person.crop.circle.badge.xmark", message: "Allow Contacts access to resolve caller names and add contacts.")
                } else {
                    List(filtered) { contact in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(contact.displayName).font(.headline)
                            ForEach(contact.phones, id: \.self) { phone in
                                Button(phone) { app.dialString = phone }
                                    .font(.subheadline)
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "Search contacts")
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { app.requestContacts() } label: { Image(systemName: "arrow.clockwise") }
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus") }
                }
            }
            .onAppear { app.requestContacts() }
            .sheet(isPresented: $showAdd) { NewContactView() }
        }
    }
}

struct NewContactView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppModel
    @State private var name = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Phone number", text: $phone)
                    .keyboardType(.phonePad)
                Button("Save") {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !phone.isEmpty else { return }
                    app.contacts.addContact(name: name, phone: phone)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || phone.isEmpty)
            }
            .navigationTitle("New Contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}


struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding()
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("IKOS K7 — BLE Control") {
                    HStack { Text("Status"); Spacer(); Text(app.bleStatus).foregroundStyle(.secondary) }
                    HStack { Text("Device"); Spacer(); Text(app.deviceName).foregroundStyle(.secondary) }
                    Picker("SIM slot", selection: $app.simSlot) {
                        Text("SIM 1").tag(0)
                        Text("SIM 2").tag(1)
                    }
                    Button("Refresh device info") { app.requestDeviceInfo() }
                    HStack { Text("Battery"); Spacer(); Text(app.battery).foregroundStyle(.secondary) }
                    HStack { Text("Firmware"); Spacer(); Text(app.firmware).foregroundStyle(.secondary).lineLimit(1) }
                    HStack { Text("IMEI"); Spacer(); Text(app.imei).foregroundStyle(.secondary) }
                }

                Section("Calling") {
                    Toggle("Auto connect", isOn: $app.autoConnect)
                    Toggle("Resolve caller names", isOn: $app.resolveCallerNames)
                    Toggle("Missed-call notifications", isOn: $app.missedCallNotifications)
                    Toggle("Speaker by default", isOn: $app.speakerDefault)
                }

                Section("Permissions") {
                    Button("Allow Contacts") { app.requestContacts() }
                    Button("Allow Notifications") { app.notifications.requestPermission() }
                }

                Section("Hotspot Audio — Wi-Fi / UDP") {
                    HStack { Text("Status"); Spacer(); Text(app.wifiStatus).foregroundStyle(.secondary).lineLimit(1) }
                    TextField("J7 hotspot IP", text: $app.j7Host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    Text("Audio uses Wi-Fi/UDP. CallKit, answer/end, dial commands and SMS events use BLE GATT. In this hybrid build, the iPhone microphone TX is disabled; J7's native GSM microphone remains the uplink.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    NavigationLink("Live Log") { DiagnosticLogView() }
                }

                Section("About") {
                    HStack { Text("CALLSHARE Hybrid"); Spacer(); Text("Prototype R1") }
                    Text("BLE service: \(K7Protocol.service.uuidString)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct DiagnosticLogView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(app.logs.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("Diagnostic Log")
    }
}
