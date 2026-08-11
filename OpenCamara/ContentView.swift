import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var localization: LocalizationManager
    @StateObject private var camera = CameraManager()
    @StateObject private var storage = StorageManager()
    @State private var captureMode: MediaKind = .photo
    @State private var isShowingSettings = false
    @State private var flashVisible = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session, isMirrored: camera.isMirroringEnabled)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.68), .clear, .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if flashVisible {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                cameraStateOverlay
                Spacer()
                captureControls
            }
            .padding(24)

            if !storage.hasSaveLocation {
                firstRunOverlay
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(storage: storage)
                .preferredColorScheme(.dark)
        }
        .onAppear {
            camera.requestPermissionsAndStart()
        }
        .onChange(of: camera.lastCapturedURL) {
            storage.refreshItems()
        }
        .onChange(of: camera.flashCount) {
            withAnimation(.easeOut(duration: 0.05)) { flashVisible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeIn(duration: 0.16)) { flashVisible = false }
            }
        }
        .alert(localization.string("提示"), isPresented: errorPresented) {
            Button(localization.string("好")) {
                camera.errorMessage = nil
                storage.errorMessage = nil
            }
        } message: {
            Text(camera.errorMessage ?? storage.errorMessage ?? localization.string("发生未知错误。"))
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "camera.aperture")
                    .font(.title2.weight(.semibold))
                Text("OpenCamara")
                    .font(.headline)
            }
            .padding(.horizontal, 15)
            .frame(height: 44)
            .background(.black.opacity(0.42), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.13)))

            Spacer()

            Button {
                storage.chooseSaveFolder()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                    Text(storage.baseURL?.lastPathComponent ?? localization.string("设置保存位置"))
                        .lineLimit(1)
                }
                .padding(.horizontal, 15)
                .frame(height: 44)
                .background(.black.opacity(0.42), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.13)))
            }
            .buttonStyle(.plain)
            .help(storage.locationDisplayName)
            .disabled(camera.isRecording || camera.isProcessingVideo)

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.42), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.13)))
            }
            .buttonStyle(.plain)
            .help(localization.string("设置"))
            .disabled(camera.isRecording || camera.isProcessingVideo)
        }
    }

    @ViewBuilder
    private var cameraStateOverlay: some View {
        switch camera.state {
        case .preparing:
            statusPill(icon: "camera.fill", text: localization.string("正在准备摄像头…"), showsProgress: true)
        case .permissionDenied:
            VStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 34))
                Text(localization.string("需要摄像头权限"))
                    .font(.title3.weight(.semibold))
                Text(localization.string("请在“系统设置 → 隐私与安全性 → 相机”中允许 OpenCamara。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(localization.string("打开系统设置")) { openCameraPrivacySettings() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        case .unavailable:
            statusPill(icon: "camera.fill", text: localization.string("没有检测到可用的摄像头"), showsProgress: false)
        case .ready:
            if camera.isProcessingVideo {
                statusPill(icon: "film.fill", text: localization.string("正在保存 MP4…"), showsProgress: true)
            } else if camera.isRecording {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(formatDuration(camera.recordingDuration))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(.black.opacity(0.62), in: Capsule())
            }
        }
    }

    private var captureControls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 4) {
                modeButton(.photo)
                modeButton(.video)
            }
            .padding(4)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12)))
            .disabled(camera.isRecording || camera.isProcessingVideo)

            HStack(spacing: 24) {
                mirrorButton
                    .frame(width: 74)

                Button(action: performCapture) {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 74, height: 74)
                        if captureMode == .photo {
                            Circle()
                                .fill(.white)
                                .frame(width: 60, height: 60)
                        } else {
                            RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 28)
                                .fill(.red)
                                .frame(
                                    width: camera.isRecording ? 30 : 58,
                                    height: camera.isRecording ? 30 : 58
                                )
                                .animation(.easeInOut(duration: 0.18), value: camera.isRecording)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canUseShutter)
                .opacity(canUseShutter ? 1 : 0.45)
                .keyboardShortcut(.space, modifiers: [])

                Color.clear
                    .frame(width: 74, height: 50)
            }

            Text(captureHint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 2)
    }

    private var firstRunOverlay: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.72)).ignoresSafeArea()
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(.blue.opacity(0.18)).frame(width: 82, height: 82)
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.blue)
                }
                VStack(spacing: 8) {
                    Text(localization.string("先选择保存位置"))
                        .font(.title2.weight(.bold))
                    Text(localization.string("只需设置一次。照片和录像将按日期自动整理，\n以后也可以随时在设置中更改。"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                }
                HStack(spacing: 22) {
                    Label(localization.string("JPG 照片"), systemImage: "photo.fill")
                    Label(localization.string("MP4 录像"), systemImage: "video.fill")
                    Label(localization.string("按日期归档"), systemImage: "calendar")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Button(localization.string("选择文件夹…")) { storage.chooseSaveFolder() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.blue)
            }
            .padding(36)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        }
    }

    private func modeButton(_ mode: MediaKind) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { captureMode = mode }
        } label: {
            Text(mode.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(captureMode == mode ? .black : .white.opacity(0.74))
                .frame(width: 72, height: 32)
                .background(captureMode == mode ? .white : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var mirrorButton: some View {
        Button {
            camera.toggleMirroring()
        } label: {
            ZStack {
                Circle()
                    .fill(camera.isMirroringEnabled ? Color.blue : Color.black.opacity(0.55))
                    .frame(width: 48, height: 48)
                Circle()
                    .stroke(.white.opacity(camera.isMirroringEnabled ? 0.35 : 0.16))
                    .frame(width: 48, height: 48)
                Image(systemName: "arrow.left.and.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(camera.state != .ready || camera.isRecording || camera.isProcessingVideo || camera.isCapturingPhoto)
        .opacity(camera.state == .ready ? 1 : 0.45)
        .help(localization.string(camera.isMirroringEnabled ? "关闭镜像" : "开启镜像"))
        .accessibilityLabel(localization.string(camera.isMirroringEnabled ? "关闭镜像" : "开启镜像"))
    }

    private func statusPill(icon: String, text: String, showsProgress: Bool) -> some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
            }
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(.black.opacity(0.62), in: Capsule())
    }

    private var canUseShutter: Bool {
        storage.hasSaveLocation && camera.state == .ready && !camera.isProcessingVideo && !camera.isCapturingPhoto
    }

    private var captureHint: String {
        if camera.isProcessingVideo { return localization.string("正在完成录像，请稍候") }
        if camera.isRecording { return localization.string("再次点击结束录像") }
        return localization.string(captureMode == .photo ? "按空格键拍照" : "按空格键开始录像")
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { camera.errorMessage != nil || storage.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    camera.errorMessage = nil
                    storage.errorMessage = nil
                }
            }
        )
    }

    private func performCapture() {
        do {
            switch captureMode {
            case .photo:
                let url = try storage.makeDestinationURL(for: .photo)
                camera.capturePhoto(to: url)
            case .video:
                if camera.isRecording {
                    camera.stopRecording()
                } else {
                    let url = try storage.makeDestinationURL(for: .video)
                    camera.startRecording(to: url)
                }
            }
        } catch {
            storage.errorMessage = error.localizedDescription
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func openCameraPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}
