import SurveyCore
import SwiftUI

struct MQTTSettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        Form {
            Group {
                Section {
                    Text("Streams every record live to an MQTT broker your team runs, in the NS Messaging format. Most people don't need this: Files and NS Analytics work without a server.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.ink2)
                }
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
                    AppliesNextSurveyFooter(extra: "Client records go on the 80211_client_message topic, new in NS Messaging 2.7.0.")
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
                    Text("Streams every record live to a gRPC server your team runs, in the NS Messaging format. Most people don't need this: Files and NS Analytics work without a server.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.ink2)
                }
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
