import SurveyCore
import SwiftUI

struct MQTTSettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        Form {
            Group {
                Section {
                    Toggle("Stream to MQTT", isOn: settings.binding(Settings.destinationMQTT))
                        .accessibilityIdentifier("mqtt.enabled")
                } footer: {
                    if settings[Settings.destinationMQTT] && settings[Settings.mqttHost].isEmpty {
                        Label("Enter a broker host to stream.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.amberText)
                    }
                }
                Section("Broker") {
                    SettingTextField(title: "Host", text: settings.binding(Settings.mqttHost),
                                     prompt: "broker.example.com", keyboard: .URL, identifier: "mqtt.host")
                    SettingNumberField(title: "Port", value: settings.binding(Settings.mqttPort), range: 1...65535,
                                       identifier: "mqtt.port")
                    Toggle("TLS", isOn: settings.binding(Settings.mqttTLSEnabled))
                        .accessibilityIdentifier("mqtt.tls")
                    SettingTextField(title: "Client ID", text: settings.binding(Settings.mqttClientID),
                                     prompt: "Automatic", identifier: "mqtt.clientID")
                }
                Section("Sign in") {
                    SettingTextField(title: "Username", text: settings.binding(Settings.mqttUsername),
                                     prompt: "None", identifier: "mqtt.username")
                    SecretField(title: "Password", key: Secrets.mqttPassword, identifier: "mqtt.password")
                }
                Section {
                    SettingTextField(title: "Topic prefix", text: settings.binding(Settings.mqttTopicPrefix),
                                     prompt: "None", identifier: "mqtt.prefix")
                    SettingNumberField(title: "Queue size", value: settings.binding(Settings.streamingQueueLimit),
                                       identifier: "mqtt.queue")
                } header: {
                    Text("Messages")
                } footer: {
                    Text("The prefix goes in front of every topic, for example \"site1/\". The queue holds records while the broker is unreachable; 0 means no limit. The queue size also applies to gRPC.")
                }
                Section {
                    Toggle("Stream client records", isOn: settings.binding(Settings.mqttStreamClientRecords))
                } header: {
                    Text("Experimental")
                } footer: {
                    AppliesNextSurveyFooter(extra: "Client (station) records use a proposed topic that is not part of NS Messaging yet.")
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle("MQTT")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GRPCSettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        Form {
            Group {
                Section {
                    Toggle("Stream to gRPC", isOn: settings.binding(Settings.destinationGRPC))
                        .accessibilityIdentifier("grpc.enabled")
                } footer: {
                    if settings[Settings.destinationGRPC] && settings[Settings.grpcHost].isEmpty {
                        Label("Enter a server host to stream.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.amberText)
                    }
                }
                Section {
                    SettingTextField(title: "Host", text: settings.binding(Settings.grpcHost),
                                     prompt: "server.example.com", keyboard: .URL, identifier: "grpc.host")
                    SettingNumberField(title: "Port", value: settings.binding(Settings.grpcPort), range: 1...65535,
                                       identifier: "grpc.port")
                    Toggle("TLS", isOn: settings.binding(Settings.grpcTLSEnabled))
                } header: {
                    Text("Server")
                } footer: {
                    AppliesNextSurveyFooter()
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle("gRPC")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// NS CSV, WiGLE CSV and pcapng.
struct FileSettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        Form {
            Group {
                Section {
                    Toggle("Save files on this iPhone", isOn: settings.binding(Settings.destinationLogFiles))
                        .accessibilityIdentifier("files.enabled")
                } footer: {
                    Text("Network Survey CSV files: Wi-Fi, Bluetooth, clients and probe requests, one file of each per survey.")
                }
                Section {
                    Toggle("WiGLE CSV", isOn: settings.binding(Settings.logWigleCSV))
                        .disabled(!settings[Settings.destinationLogFiles])
                        .accessibilityIdentifier("files.wigle")
                } footer: {
                    Text("A file in the WiGLE upload format. Rows without a location are left out.")
                }
                Section {
                    LabeledContent("pcapng") {
                        Text(settings[Settings.surveyRawFrames] ? "On" : "Off")
                    }
                } footer: {
                    Text("To save a packet capture (pcapng), turn on Raw frames on the Survey tab.")
                }
                Section {
                    EmptyView()
                } footer: {
                    AppliesNextSurveyFooter(extra: "Files are in the Files tab and in the Files app under On My iPhone > Network Survey.")
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
    }
}
