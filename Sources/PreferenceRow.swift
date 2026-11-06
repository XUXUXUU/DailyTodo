import SwiftUI

/// 引导与设置共用同一控件列，避免状态文字长度挤歪开关。
struct PreferenceRow<Control:View>: View {
    let title:String
    let icon:String
    var help:String? = nil
    var controlWidth: CGFloat = 52
    @ViewBuilder var control:Control
    var body:some View {
        HStack(spacing:12) {
            Image(systemName:icon).font(.system(size:16)).foregroundStyle(Color(nsColor:.systemBlue)).frame(width:22)
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(.system(size:14,weight:.medium))
                if let help, !help.isEmpty { Text(help).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            }
            Spacer(minLength:12)
            control.frame(width:controlWidth,alignment:.trailing)
        }.padding(.horizontal,16).frame(minHeight:56).padding(.vertical,help == nil ? 0 : 5)
    }
}
struct AlignedPreferenceToggle: View {
    let title:String
    let icon:String
    var help:String? = nil
    @Binding var isOn:Bool
    var disabled=false
    var body:some View {
        PreferenceRow(title:title,icon:icon,help:help) {
            Toggle(title,isOn:$isOn).labelsHidden().toggleStyle(PreferenceSwitchStyle())
                .accessibilityLabel(title).accessibilityHint(help ?? "").disabled(disabled)
        }
    }
}

/// 跟随实际绑定与可操作性，避免系统在非活动窗口把 ON 轨道降为灰色。
private struct PreferenceSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchControl(configuration: configuration)
    }

    private struct SwitchControl: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @FocusState private var focused: Bool
        @State private var hovered = false

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? Color(red: 10/255, green: 132/255, blue: 1) : Color(nsColor: .systemGray).opacity(enabled ? 0.75 : 0.36))
                    .frame(width: 44, height: 24)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Color.white.opacity(enabled || configuration.isOn ? 1 : 0.58))
                            .frame(width: 18, height: 18).padding(3)
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    }
                    .overlay(Capsule().strokeBorder(focused ? Color.accentColor : .white.opacity(hovered && enabled ? 0.35 : 0.15), lineWidth: focused ? 2 : 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .onHover { hovered = $0 }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
            }
        }
    }
}
