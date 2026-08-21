import SwiftUI

/// Speed, pitch, and tone, on sliders rather than in a menu.
///
/// Speed is at the top because it is the one people reach for. Everything
/// below it needs a downloaded file, and says so when there is not one.
struct EffectsPanel: View {
    @Environment(AppModel.self) private var model

    private var player: Player { model.player }

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sound").font(.headline)
                Spacer()
                Button("Reset") { model.player.effects = .flat }
                    .disabled(player.effects.isFlat)
            }

            slider(
                "Speed",
                value: Binding(
                    get: { player.effects.rate },
                    set: { model.player.effects.rate = $0 }),
                range: AudioEffects.rateRange,
                format: { String(format: "%.2f×", $0) },
                ticks: [0.75, 1.0, 1.5, 2.0, 2.5])

            Divider()

            if !player.canUseEngine {
                Label(
                    "Pitch and tone need the title downloaded. A streamed title "
                    + "can still change speed.",
                    systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                slider(
                    "Pitch",
                    value: Binding(
                        get: { player.effects.pitch },
                        set: { model.player.effects.pitch = $0 }),
                    range: AudioEffects.pitchRange,
                    format: { String(format: "%+.0f cents", $0) },
                    ticks: [-600, 0, 600])

                slider(
                    "Bass",
                    value: Binding(
                        get: { player.effects.bass },
                        set: { model.player.effects.bass = $0 }),
                    range: AudioEffects.bandRange,
                    format: { String(format: "%+.1f dB", $0) })

                slider(
                    "Voice",
                    value: Binding(
                        get: { player.effects.mid },
                        set: { model.player.effects.mid = $0 }),
                    range: AudioEffects.bandRange,
                    format: { String(format: "%+.1f dB", $0) })

                slider(
                    "Treble",
                    value: Binding(
                        get: { player.effects.treble },
                        set: { model.player.effects.treble = $0 }),
                    range: AudioEffects.bandRange,
                    format: { String(format: "%+.1f dB", $0) })

                slider(
                    "Volume",
                    value: Binding(
                        get: { player.effects.gain },
                        set: { model.player.effects.gain = $0 }),
                    range: AudioEffects.gainRange,
                    format: { String(format: "%+.1f dB", $0) })
            }
            .disabled(!player.canUseEngine)

            Divider()

            HStack(spacing: 6) {
                ForEach(AudioEffects.presets, id: \.name) { preset in
                    Button(preset.name) {
                        var next = preset.effects
                        // A preset changes the sound, not how fast it plays.
                        next.rate = model.player.effects.rate
                        model.player.effects = next
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!player.canUseEngine && preset.name != "Flat")
                }
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func slider(
        _ label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        format: @escaping (Float) -> String,
        ticks: [Float] = []
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) {
                Text(label)
            } minimumValueLabel: {
                Text("").font(.caption2)
            } maximumValueLabel: {
                Text("").font(.caption2)
            }
            if !ticks.isEmpty {
                HStack(spacing: 4) {
                    ForEach(ticks, id: \.self) { tick in
                        Button(format(tick)) { value.wrappedValue = tick }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(
                                abs(value.wrappedValue - tick) < 0.001
                                    ? Color.accentColor : Color.secondary)
                    }
                }
            }
        }
    }
}
