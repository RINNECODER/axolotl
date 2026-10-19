// Luna — the speaker on tabs playing sound; click mutes or unmutes the site.
import SwiftUI

struct TabAudioState {
    var isAudible = false
    var isMuted = false
    var toggle: (() -> Void)?

    static let silent = TabAudioState()

    /// Chrome shows the speaker while a tab plays sound, and the crossed-out one on muted tabs.
    var isShown: Bool { isAudible || isMuted }

    init(isAudible: Bool = false, isMuted: Bool = false, toggle: (() -> Void)? = nil) {
        self.isAudible = isAudible
        self.isMuted = isMuted
        self.toggle = toggle
    }

    init(web: WebViewWrapper, tabId: UUID) {
        isAudible = web.audibleTabs.contains(tabId)
        isMuted = web.isMuted(tabId)
        toggle = { [weak web] in
            guard let web else { return }
            web.setMuted(!web.isMuted(tabId), tab: tabId)
        }
    }
}

struct TabAudioButton: View {
    let audio: TabAudioState
    var color: Color = .secondary

    var body: some View {
        if audio.isShown {
            let image = Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            if let toggle = audio.toggle {
                Button(action: toggle) { image }
                    .buttonStyle(.plain)
                    .help(audio.isMuted ? "Unmute Site" : "Mute Site")
                    .accessibilityLabel(audio.isMuted ? "Unmute Site" : "Mute Site")
            } else {
                image.accessibilityLabel(audio.isMuted ? "Muted" : "Playing audio")
            }
        }
    }
}
