import SwiftUI

@main
struct EveApp: App {
    var body: some Scene {
        WindowGroup {
            ShellView()
        }
    }
}

struct ShellView: View {
    @StateObject private var model = ShellModel()
    @ObservedObject private var revoker = SessionRevoker.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            WebViewContainer(model: model)
                .ignoresSafeArea()
            if model.offline {
                OfflineView(retry: model.reload, unpair: { model.showUnpairConfirm = true })
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { RevokeBanner(state: revoker.state, dismiss: revoker.dismissFailure) }
        // L1: retry a pending server-side session revoke at launch, on foreground and when the network returns.
        .task { SessionRevoker.shared.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await SessionRevoker.shared.retryPending() } }
        }
        // Shell settings: three-finger long press opens the unpair dialog.
        .confirmationDialog("Eve shell \(ShellConfig.shellVersion)", isPresented: $model.showUnpairConfirm) {
            Button("Unpair this device", role: .destructive) { model.unpair() }
            Button("Reload") { model.reload() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unpair signs out, deletes all cookies and website data stored by this app, and revokes the server session (retried automatically if you are offline).")
        }
    }
}

struct OfflineView: View {
    let retry: () -> Void
    let unpair: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash").font(.system(size: 44))
            Text("Tailscale 연결 확인").font(.title2.bold())
            Text("Eve 서버에 연결할 수 없습니다. Tailscale이 켜져 있고 tailnet에 연결되어 있는지 확인하세요.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("다시 시도", action: retry).buttonStyle(.borderedProminent)
            Button("Unpair", role: .destructive, action: unpair).font(.footnote)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

/// Shows the state of a server-side session revoke after unpair (never silently pending or failed).
struct RevokeBanner: View {
    let state: RevokeState
    let dismiss: () -> Void
    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .pending:
            banner("서버 세션 해지 대기 중 · 연결되면 자동으로 다시 시도해요.")
        case .failed:
            banner("서버 세션 해지 실패 · 관리자에서 세션을 해지해 주세요. (탭하면 닫기)")
                .onTapGesture(perform: dismiss)
        }
    }
    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
    }
}
