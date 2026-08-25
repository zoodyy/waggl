//
//  ContentView.swift
//  waggl
//

import SwiftUI

struct ContentView: View {
    @StateObject private var filler = StorageFiller()
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 64))
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, isActive: filler.isRunning)

            Text("Zero Filler")
                .font(.largeTitle.bold())

            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if filler.isRunning || filler.phase == .done || filler.phase == .cancelled {
                statsPanel
                    .transition(.opacity)
            }

            if case .failed(let message) = filler.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            if !filler.isRunning {
                passesSelector
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            actionButton
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
        .padding()
        .animation(.default, value: filler.phase)
        .alert("Fill up storage?", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Fill it up", role: .destructive) { filler.start() }
        } message: {
            Text("This writes a file of zeros until this device's storage is completely full, then deletes it — \(passCountPhrase). The device may briefly become unresponsive and other apps could run out of space while it runs.")
        }
    }

    // MARK: - Pieces

    private var passesSelector: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Passes")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(filler.passes)× create + delete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Passes", selection: $filler.passes) {
                ForEach(1...5, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var statsPanel: some View {
        VStack(spacing: 14) {
            if filler.totalPasses > 1 || filler.isRunning {
                let pass = max(1, filler.currentPass)
                Text("Pass \(pass) of \(filler.totalPasses) — writing all \(pass.isMultiple(of: 2) ? "1" : "0")s")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            ProgressView(value: filler.progress)
                .tint(.orange)

            HStack {
                statBlock(title: "Written", value: format(filler.bytesWritten))
                Divider().frame(height: 34)
                statBlock(title: "Free now", value: format(filler.availableBytes))
            }

            if filler.phase == .done {
                Label(doneSummary, systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            } else if filler.phase == .cancelled {
                Label("Cancelled — the file was deleted.", systemImage: "xmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if filler.phase == .deleting {
                Label("Storage full — deleting the file…", systemImage: "trash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private func statBlock(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionButton: some View {
        if filler.isRunning {
            Button(role: .destructive) {
                filler.cancel()
            } label: {
                Label("Cancel", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.gray)
        } else {
            Button {
                showConfirm = true
            } label: {
                Label("Fill Storage", systemImage: "externaldrive.fill.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }

    // MARK: - Presentation helpers

    private var caption: String {
        switch filler.phase {
        case .idle:
            return "Tap the button to create a file that grows until storage is full, then delete it — leaving the device exactly as before. Odd passes write all 0-bits, even passes all 1-bits."
        case .filling:
            return "Filling every free byte…"
        case .deleting:
            return "Cleaning up…"
        case .done:
            return "Done. The device is back to where it started."
        case .cancelled:
            return "Stopped early. Nothing was left behind."
        case .failed:
            return "Something went wrong."
        }
    }

    private var passCountPhrase: String {
        filler.passes == 1 ? "once" : "\(filler.passes) times in a row"
    }

    private var doneSummary: String {
        let peak = format(filler.peakBytesWritten)
        if filler.totalPasses > 1 {
            return "Filled to \(peak) and deleted, \(filler.totalPasses) times over. Nothing left behind."
        }
        return "Peaked at \(peak), then deleted. Nothing left behind."
    }

    private var iconName: String {
        switch filler.phase {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .filling, .deleting: return "externaldrive.fill"
        default: return "externaldrive"
        }
    }

    private var iconColor: Color {
        switch filler.phase {
        case .done: return .green
        case .failed: return .red
        case .filling, .deleting: return .orange
        default: return .accentColor
        }
    }

    private func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

#Preview {
    ContentView()
}
