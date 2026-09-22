import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    required property QtObject backend
    property var state: backend.state
    property int page: 0
    onPageChanged: if (scroll.contentItem) scroll.contentItem.contentY = 0
    property bool trayAvailable: false
    function t(source) { return state.translations[source] || source }
    readonly property color ink: "#23262c"
    readonly property color secondary: "#656b75"
    readonly property color accent: "#0869d8"
    readonly property var titles: [window.t("连接"), window.t("权限设置"), window.t("配对"), window.t("诊断")]
    width: 900; height: 720
    minimumWidth: 720; minimumHeight: 520
    visible: true
    title: "Viewflow"
    color: "#fafafa"
    font.family: Qt.platform.os === "windows" ? "Segoe UI" : "Noto Sans"
    font.pixelSize: 14
    palette.window: "#fafafa"
    palette.base: "#ffffff"
    palette.text: ink
    palette.windowText: ink
    palette.buttonText: ink
    palette.highlight: accent
    palette.highlightedText: "#ffffff"
    onClosing: function(close) {
        close.accepted = false
        if (trayAvailable && !state.quitting) hide()
        else backend.quit()
    }

    component BodyText: Label {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        color: window.secondary
        lineHeight: 1.25
    }
    component Heading: Label {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        font.pixelSize: 16
        font.weight: Font.DemiBold
        color: window.ink
    }
    component ActionButton: Button {
        id: control
        property bool primary: false
        Layout.maximumWidth: parent.width
        padding: 10
        leftPadding: 14; rightPadding: 14
        implicitHeight: Math.max(36, contentItem.implicitHeight + topPadding + bottomPadding)
        hoverEnabled: true
        contentItem: Text {
            text: control.text
            wrapMode: Text.Wrap
            font: control.font
            color: !control.enabled ? "#9298a1" : control.primary ? "white" : window.ink
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 6
            color: !control.enabled ? "#edf0f4" : control.primary ? (control.down ? "#0753ad" : control.hovered ? "#1479ed" : window.accent) : (control.down ? "#e4e7ed" : control.hovered ? "#f0f2f5" : "white")
            border.width: control.activeFocus ? 2 : 1
            border.color: control.activeFocus ? window.accent : control.primary ? "transparent" : "#d4d7de"
        }
    }
    component Card: Pane {
        Layout.fillWidth: true
        padding: 16
        background: Rectangle {
            radius: 9
            color: "white"
            border.color: "#e0e2e7"
        }
    }
    component SettingSwitch: Switch {
        id: control
        property bool labelVisible: true
        Layout.fillWidth: labelVisible
        implicitHeight: Math.max(36, label.implicitHeight)
        implicitWidth: labelVisible ? label.implicitWidth : 44
        spacing: 8
        Accessible.name: text
        indicator: Rectangle {
            x: 0; y: (control.height - height) / 2
            width: 40; height: 24; radius: 12
            color: control.checked ? window.accent : "#d9dde4"
            border.color: control.activeFocus ? window.accent : "transparent"
            border.width: control.activeFocus ? 2 : 0
            Rectangle {
                x: control.checked ? 18 : 2; y: 2
                width: 20; height: 20; radius: 10
                color: "white"
            }
        }
        contentItem: Text {
            id: label
            visible: control.labelVisible
            leftPadding: 48
            text: control.text
            wrapMode: Text.Wrap
            font: control.font
            color: window.ink
            verticalAlignment: Text.AlignVCenter
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        Rectangle {
            Layout.preferredWidth: 180
            Layout.fillHeight: true
            color: "#eef0f4"
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 6
                RowLayout {
                    Layout.topMargin: 19; Layout.bottomMargin: 28; Layout.leftMargin: 10
                    Image { source: "viewflow.svg"; sourceSize.width: 28; sourceSize.height: 28 }
                    Label { text: "Viewflow"; color: window.ink; font.pixelSize: 20; font.weight: Font.DemiBold }
                }
                Repeater {
                    model: window.titles
                    delegate: ItemDelegate {
                        id: navigation
                        required property string modelData
                        required property int index
                        Layout.fillWidth: true
                        implicitHeight: 42
                        text: modelData
                        highlighted: window.page === index
                        Accessible.name: modelData
                        onClicked: window.page = index
                        contentItem: RowLayout {
                            spacing: 11
                            Image {
                                source: ["connection.svg", "permissions.svg", "pairing.svg", "diagnostics.svg"][navigation.index]
                                sourceSize.width: 20; sourceSize.height: 20
                            }
                            Label { text: navigation.modelData; color: window.ink; font.weight: navigation.highlighted ? Font.DemiBold : Font.Normal; Layout.fillWidth: true }
                        }
                        background: Rectangle {
                            radius: 6
                            color: navigation.highlighted ? "#dbe5f4" : navigation.hovered ? "#e4e8ef" : "transparent"
                            border.color: navigation.activeFocus ? window.accent : "transparent"
                        }
                    }
                }
                Item { Layout.fillHeight: true }
                Label { text: window.t("语言"); color: window.secondary }
                ComboBox {
                    Layout.fillWidth: true
                    Accessible.name: window.t("语言")
                    model: [window.t("跟随系统"), "简体中文", "English"]
                    currentIndex: ["system", "zh-CN", "en"].indexOf(window.state.languagePreference)
                    onActivated: window.backend.setLanguage(["system", "zh-CN", "en"][currentIndex])
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: "#dce0e6" }
                Label {
                    Layout.margins: 10
                    text: window.state.platform === "windows" ? "Windows" : "Linux"
                    color: window.secondary
                    font.pixelSize: 12
                }
                ActionButton {
                    Layout.fillWidth: true
                    text: window.state.quitting ? window.t("正在退出…") : window.t("退出 Viewflow")
                    enabled: !window.state.quitting
                    onClicked: window.backend.quit()
                }
            }
        }
        Rectangle { Layout.fillHeight: true; width: 1; color: "#dce0e6" }
        ScrollView {
            id: scroll
            objectName: "pageScroll"
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ColumnLayout {
                width: scroll.availableWidth
                spacing: 0
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.margins: 28
                    spacing: 20
                    enabled: !window.state.quitting
                    Label { text: window.titles[window.page]; color: window.ink; font.pixelSize: 30; font.weight: Font.DemiBold }

                    ColumnLayout {
                        visible: window.page === 0
                        Layout.fillWidth: true
                        spacing: 16
                        BodyText { text: window.t("窗口、输入、剪贴板和触控板，在一个应用里管理。") }
                        Card {
                            visible: !window.state.paired
                            ColumnLayout {
                                width: parent.width
                                spacing: 10
                                Heading { text: window.t("首次使用") }
                                BodyText { text: window.t("1. 导入配对文件\n2. 设置这台电脑需要的权限与组件\n3. 启动连接") }
                                ActionButton { text: window.t("导入配对文件"); primary: true; onClicked: window.backend.action("importProfile") }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 14
                            ColumnLayout {
                                Layout.fillWidth: true
                                Heading { text: window.state.profileName; Layout.fillWidth: true; elide: Text.ElideRight }
                                Label { text: window.state.transitioning ? window.t("正在结束连接…") : window.state.running ? window.t("已启用连接") : window.t("连接已停止"); color: window.secondary; font.pixelSize: 12 }
                            }
                            ActionButton {
                                text: window.state.running ? window.t("停止全部") : window.t("启动")
                                primary: true
                                enabled: window.state.running || (window.state.paired && !window.state.transitioning)
                                onClicked: window.backend.action(window.state.running ? "stop" : "start")
                            }
                        }
                        Repeater {
                            model: window.backend.components
                            delegate: Card {
                                required property var modelData
                                RowLayout {
                                    width: parent.width
                                    spacing: 12
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Heading { text: modelData.title; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                        BodyText { text: modelData.status; font.pixelSize: 12 }
                                    }
                                    SettingSwitch {
                                        text: modelData.title
                                        labelVisible: false
                                        checked: modelData.enabled
                                        onToggled: window.backend.setComponentEnabled(modelData.id, checked)
                                    }
                                }
                            }
                        }
                        Card {
                            ColumnLayout {
                                width: parent.width
                                spacing: 10
                                Heading { text: window.t("收回本机窗口") }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    TextField {
                                        id: shortcut
                                        width: 205; height: 36
                                        text: window.state.recallShortcut
                                        placeholderText: "Ctrl+Alt+Shift+H"
                                        Accessible.name: window.t("收回窗口快捷键")
                                        selectByMouse: true
                                        onAccepted: window.backend.applyShortcut(text)
                                    }
                                    ActionButton { text: window.t("应用快捷键"); enabled: !window.state.busy; onClicked: window.backend.applyShortcut(shortcut.text) }
                                    ActionButton { text: window.t("立即收回"); enabled: !window.state.busy; onClicked: window.backend.action("recall") }
                                }
                                BodyText { text: window.state.recallStatus || window.t("使用快捷键将共享出去的窗口收回这台电脑。"); font.pixelSize: 12 }
                            }
                        }
                        BodyText { text: window.t("“正在运行”表示组件已启动；实际连接和操作效果仍需在两端确认。"); font.pixelSize: 12 }
                    }

                    ColumnLayout {
                        visible: window.page === 1
                        Layout.fillWidth: true
                        spacing: 16
                        BodyText { text: window.t("按需要设置这台电脑。缺少某项权限时，其余功能仍可使用。") }
                        ActionButton { text: window.state.busy ? window.t("正在检查…") : window.t("检查权限与组件"); enabled: !window.state.busy; onClicked: window.backend.action("checkPermissions") }
                        BodyText { visible: window.state.permissionRows.length === 0; text: window.t("尚未检查") }
                        Card {
                            visible: window.state.permissionRows.length > 0
                            ColumnLayout {
                                width: parent.width; spacing: 16
                                Repeater {
                                    model: window.state.permissionRows
                                    delegate: ColumnLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 6
                                        RowLayout {
                                            Layout.fillWidth: true
                                            Heading { text: modelData.title }
                                            Label {
                                                text: modelData.status
                                                color: modelData.tone === "good" ? "#187344" : modelData.tone === "warning" ? "#8a5400" : window.secondary
                                                font.weight: Font.DemiBold
                                            }
                                        }
                                        BodyText { text: modelData.detail }
                                    }
                                }
                            }
                        }
                        BodyText { text: window.t("检查只读取状态，不会发送键盘、鼠标或触控板输入。"); font.pixelSize: 12 }
                        Card {
                            visible: window.state.platform === "windows"
                            ColumnLayout {
                                width: parent.width; spacing: 10
                                Heading { text: window.t("锁屏输入服务") }
                                BodyText { text: window.t("普通窗口、输入和剪贴板使用当前登录会话。需要操作 Windows 锁屏时，安装内置输入服务；系统会请求管理员权限。") }
                                ActionButton { text: window.t("安装 / 更新锁屏输入服务"); onClicked: window.backend.action("installService") }
                                SettingSwitch { text: window.t("通过输入服务接收锁屏输入"); checked: window.state.lockInput; onToggled: window.backend.setOption("lockInput", checked) }
                            }
                        }
                        Card {
                            visible: window.state.platform === "windows"
                            ColumnLayout {
                                width: parent.width; spacing: 10
                                Heading { text: window.t("本地网络与触控板") }
                                BodyText { text: window.t("首次联网时，按 Windows 提示允许 Viewflow。原生触控板组件随应用内置，无需另装 Viewflow HID 驱动。") }
                                ActionButton { text: window.t("打开防火墙设置"); onClicked: window.backend.action("firewall") }
                            }
                        }
                        Card {
                            visible: window.state.platform === "linux"
                            ColumnLayout {
                                width: parent.width; spacing: 10
                                Heading { text: window.t("Hyprland 窗口共享") }
                                BodyText { text: window.t("插件随应用安装。先检查当前 Hyprland 构建；版本匹配后，可直接加载或复制命令在终端执行，不需要 root。") }
                                ActionButton { text: window.t("加载 Viewflow 插件"); enabled: !window.state.busy && window.state.pluginCommands.length > 0; onClicked: window.backend.action("loadPlugins") }
                                TextArea {
                                    visible: window.state.pluginCommands.length > 0
                                    Layout.fillWidth: true
                                    text: window.state.pluginCommands
                                    readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
                                    Accessible.name: window.t("插件加载命令")
                                    color: window.ink
                                }
                                ActionButton {
                                    visible: window.state.pluginCommands.length > 0
                                    text: window.t("复制命令")
                                    onClicked: window.backend.copyPluginCommands()
                                }
                                BodyText { visible: window.state.pluginCommands.length === 0; text: window.t("无需重复加载已加载的插件。若版本不匹配或检查失败，请先解决上方检查结果。") }
                                BodyText { text: window.t("命令仅加载当前会话，不改写桌面配置。Hyprland 升级后需要匹配新构建的插件。"); font.pixelSize: 12 }
                            }
                        }
                        Card {
                            visible: window.state.platform === "linux"
                            ColumnLayout {
                                width: parent.width; spacing: 10
                                Heading { text: window.t("媒体编解码") }
                                BodyText { text: window.t("停止连接后更改，下次启动生效。多 GPU 请选择具体设备。") }
                                ComboBox {
                                    Layout.fillWidth: true
                                    enabled: window.state.mediaEditable
                                    model: [window.t("自动"), "NVIDIA · NVENC / NVDEC", "AMD / Intel · VA-API"]
                                    currentIndex: ["auto", "nvidia", "vaapi"].indexOf(window.state.mediaBackend)
                                    onActivated: window.backend.setMedia(["auto", "nvidia", "vaapi"][currentIndex], window.state.mediaRenderNode)
                                    Accessible.name: window.t("媒体后端")
                                }
                                ComboBox {
                                    Layout.fillWidth: true
                                    enabled: window.state.mediaEditable
                                    property var devices: [{node: "", label: window.t("自动选择设备")}].concat(window.state.mediaDevices)
                                    model: devices
                                    textRole: "label"
                                    currentIndex: { for (var i = 0; i < devices.length; ++i) if (devices[i].node === window.state.mediaRenderNode) return i; return -1; }
                                    onActivated: window.backend.setMedia(window.state.mediaBackend, devices[currentIndex].node)
                                    Accessible.name: window.t("媒体设备")
                                }
                                BodyText { visible: window.state.mediaRenderNode.length > 0; text: window.state.mediaRenderNode }
                                ActionButton { text: window.t("检查硬件媒体链路"); enabled: !window.state.busy; onClicked: window.backend.action("checkMedia") }
                                Label {
                                    text: window.state.mediaReport.ok === true ? window.t("合成媒体检查通过") : window.state.mediaReport.ok === false ? window.t("媒体检查未通过") : window.t("尚未检查")
                                    color: window.state.mediaReport.ok === true ? "#187344" : window.state.mediaReport.ok === false ? "#8a5400" : window.secondary
                                    font.weight: Font.DemiBold
                                }
                                BodyText { visible: window.state.mediaReport.ok === false; text: window.state.mediaReport.error || "" }
                                BodyText { text: window.t("检查使用离屏合成图像，验证 H.264 硬编码、硬解码、纹理导入及 alpha / atlas；不代表跨设备验收。VA-API 当前使用 CPU 准备和上传像素。") }
                            }
                        }
                        Card {
                            visible: window.state.platform === "linux"
                            ColumnLayout {
                                width: parent.width; spacing: 10
                                Heading { text: window.t("系统依赖") }
                                BodyText { text: window.t("Viewflow 只检查并提示所需组件。请通过系统包管理器自行安装，不会从 GUI 提权或修改系统软件。") }
                                Repeater {
                                    model: window.state.dependencyHints
                                    delegate: BodyText {
                                        required property string modelData
                                        text: modelData
                                    }
                                }
                            }
                        }
                        Card {
                            visible: window.state.platform === "linux"
                            ColumnLayout {
                                width: parent.width; spacing: 10
                                Heading { text: window.t("触控板设备访问") }
                                BodyText { text: window.t("原始触控板转发需要读取所选输入设备。为该设备启用本地会话访问权限后，再启动触控板组件。") }
                                ActionButton { text: window.t("打开设备权限说明"); onClicked: window.backend.action("deviceHelp") }
                            }
                        }
                        SettingSwitch { text: window.t("登录后打开 Viewflow"); checked: window.state.login; onToggled: window.backend.setOption("login", checked) }
                    }

                    ColumnLayout {
                        visible: window.page === 2
                        Layout.fillWidth: true
                        spacing: 16
                        BodyText { text: window.t("配对文件把设备身份与连接地址一起导入。") }
                        Card {
                            ColumnLayout {
                                width: parent.width; spacing: 12
                                Heading { text: window.t("当前配对") }
                                BodyText { text: window.state.profileName }
                                BodyText { visible: window.state.paired; text: window.t("连接组件：{count} 项").replace("{count}", window.state.components.length) }
                            }
                        }
                        BodyText { text: window.t("在已配对电脑上使用导出工具生成 .viewflowconnection 文件，然后在这里导入。更换配对时会先结束旧连接。") }
                        ActionButton { text: window.t("导入配对文件"); primary: true; enabled: !window.state.transitioning; onClicked: window.backend.action("importProfile") }
                        BodyText { text: window.t("配对文件包含设备私钥，请只通过你信任的方式传送。"); font.pixelSize: 12 }
                    }

                    ColumnLayout {
                        visible: window.page === 3
                        Layout.fillWidth: true
                        spacing: 16
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: window.t("版本"); color: window.secondary }
                            Item { Layout.fillWidth: true }
                            Label { text: window.state.version; color: window.ink }
                        }
                        ActionButton { text: window.t("导出诊断报告"); onClicked: window.backend.action("exportDiagnostics") }
                        ActionButton { text: window.t("打开日志文件夹"); onClicked: window.backend.action("openLogs") }
                        CheckBox {
                            id: rawDetails
                            visible: window.state.permissionDetails.length > 0
                            text: window.t("原始检查数据")
                        }
                        ScrollView {
                            visible: rawDetails.checked && window.state.permissionDetails.length > 0
                            Layout.fillWidth: true
                            Layout.preferredHeight: 240
                            contentWidth: availableWidth
                            clip: true
                            TextArea {
                                text: window.state.permissionDetails
                                readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
                                Accessible.name: window.t("原始检查数据")
                                color: window.ink
                            }
                        }
                        BodyText { text: window.t("诊断报告包含组件状态，不包含配对私钥、窗口内容或截图。日志保存在当前用户目录。") }
                    }
                    Rectangle { visible: window.state.message.length > 0; Layout.fillWidth: true; height: 1; color: "#e0e2e7" }
                    TextEdit {
                        visible: window.state.message.length > 0
                        Layout.fillWidth: true
                        text: window.state.message
                        color: window.secondary
                        font.pixelSize: 13
                        wrapMode: TextEdit.Wrap
                        readOnly: true; selectByMouse: true
                        Accessible.name: window.t("操作结果")
                    }
                }
            }
        }
    }
}
