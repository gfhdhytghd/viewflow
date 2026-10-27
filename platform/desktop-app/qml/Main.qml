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
    readonly property var titles: [window.t("连接"), window.t("权限设置"), window.t("配对"), window.t("显示器"), window.t("诊断")]
    width: 900; height: 720
    minimumWidth: 720; minimumHeight: 520
    visible: true
    title: "Viewflow"
    color: "#fafafa"
    font.family: Qt.platform.os === "windows" ? "Segoe UI" : "Noto Sans CJK SC"
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
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        color: window.secondary
        lineHeight: 1.25
    }
    component Heading: Label {
        textFormat: Text.PlainText
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
    component ConnectionIcon: Button {
        id: control
        required property string symbol
        required property string description
        implicitWidth: 36; implicitHeight: 36
        hoverEnabled: true
        Accessible.name: description
        ToolTip.visible: hovered
        ToolTip.text: description
        contentItem: Image { source: control.symbol; sourceSize.width: 20; sourceSize.height: 20; fillMode: Image.Pad; opacity: control.enabled ? 1 : 0.35 }
        background: Rectangle { radius: 6; color: control.down ? "#dce5ef" : control.hovered ? "#eef2f7" : "transparent"; border.color: control.activeFocus ? window.accent : "#d4d7de" }
    }
    component ChoiceBox: ComboBox {
        id: choice
        implicitHeight: 36
        font.family: window.font.family
        font.pixelSize: 14
        font.weight: Font.Normal
        leftPadding: 12; rightPadding: 34
        hoverEnabled: true
        contentItem: Text {
            text: choice.displayText
            font: choice.font
            color: choice.enabled ? window.ink : window.secondary
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        indicator: Image {
            source: "chevron-down.svg"
            width: 16; height: 16
            x: choice.width - width - 10; y: (choice.height - height) / 2
            opacity: choice.enabled ? 1 : 0.4
        }
        background: Rectangle {
            radius: 6
            color: choice.enabled ? (choice.hovered ? "#f6f8fb" : "white") : "#edf0f4"
            border.color: choice.activeFocus ? window.accent : "#d4d7de"
        }
        delegate: ItemDelegate {
            id: option
            required property int index
            width: choice.width - 8
            height: 36
            padding: 10
            hoverEnabled: true
            highlighted: choice.highlightedIndex === index
            contentItem: Text {
                text: choice.textAt(option.index)
                font: choice.font
                color: window.ink
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
            background: Rectangle {
                radius: 4
                color: option.highlighted ? "#dbe5f4" : option.hovered ? "#eef2f7" : "transparent"
            }
        }
        popup: Popup {
            y: choice.height + 4
            width: choice.width
            padding: 4
            implicitHeight: Math.min(contentItem.implicitHeight + 8, 240)
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: choice.popup.visible ? choice.delegateModel : null
                currentIndex: choice.highlightedIndex
                ScrollIndicator.vertical: ScrollIndicator {}
            }
            background: Rectangle { color: "white"; radius: 7; border.color: "#d4d7de" }
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
        implicitHeight: labelVisible ? Math.max(36, label.implicitHeight) : 36
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
            text: control.labelVisible ? control.text : ""
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
                                source: ["connection.svg", "permissions.svg", "pairing.svg", "connection.svg", "diagnostics.svg"][navigation.index]
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
                ChoiceBox {
                    Layout.fillWidth: true
                    objectName: "languageChoice"
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
                        Layout.maximumWidth: 740
                        Layout.alignment: Qt.AlignLeft
                        spacing: 16
                        BodyText { text: window.t("窗口、输入、剪贴板和触控板，在一个应用里管理。") }
                        Card {
                            visible: !window.state.discovery.groupID
                            ColumnLayout {
                                width: parent.width
                                spacing: 10
                                Heading { text: window.t("首次使用") }
                                BodyText { text: window.t("先选择本机作为主机或从机，再建立或加入连接组。") }
                                ActionButton { text: window.t("设置连接组"); primary: true; onClicked: window.page = 2 }
                            }
                        }
                        Card {
                            padding: 16
                            RowLayout {
                                width: parent.width; spacing: 14
                                Rectangle {
                                    implicitWidth: 42; implicitHeight: 42; radius: 10; color: "#edf3fc"
                                    Image { anchors.centerIn: parent; source: "connection.svg"; sourceSize.width: 24; sourceSize.height: 24 }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 4
                                    Heading { text: window.state.profileName; font.pixelSize: 15; wrapMode: Text.NoWrap; elide: Text.ElideRight }
                                    Label {
                                        Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 12; color: window.secondary
                                        text: window.state.transitioning ? window.t("正在同步连接组。") : window.state.running ? window.t("已启用连接") : window.t("连接已停止")
                                    }
                                }
                                ConnectionIcon {
                                    symbol: "disconnect.svg"; description: window.t("断开连接")
                                    enabled: !!window.state.discovery.groupID && !window.state.discovery.paused && !window.state.busy
                                    onClicked: window.backend.disconnectGroup()
                                }
                                ConnectionIcon {
                                    symbol: "reconnect.svg"; description: window.t("断开并重新连接")
                                    enabled: !!window.state.discovery.groupID && !window.state.busy
                                    onClicked: window.backend.reconnectGroup()
                                }
                            }
                        }
                        Repeater {
                            model: window.backend.components
                            delegate: Card {
                                required property var modelData
                                objectName: "componentCard"
                                Layout.fillHeight: false
                                padding: 16
                                RowLayout {
                                    width: parent.width; spacing: 14
                                    Item {
                                        implicitWidth: 42; implicitHeight: 42
                                        Image {
                                            anchors.centerIn: parent
                                            source: modelData.icon || "connection.svg"
                                            sourceSize.width: 32; sourceSize.height: 32
                                            opacity: modelData.enabled ? 1 : 0.5
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: 4
                                        Heading { text: modelData.displayTitle || modelData.title; font.pixelSize: 14; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                        Label {
                                            Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 12; color: window.secondary
                                            text: (modelData.deviceName ? modelData.deviceName + " · " : "") + modelData.status
                                        }
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
                                RowLayout {
                                    spacing: 10
                                    Image { source: "recall.svg"; sourceSize.width: 20; sourceSize.height: 20 }
                                    Heading { text: window.t("收回本机窗口"); font.pixelSize: 14 }
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    TextField {
                                        id: shortcut
                                        width: 190; height: 36
                                        font: window.font
                                        leftPadding: 10
                                        background: Rectangle { radius: 6; color: "#f7f8fa"; border.color: shortcut.activeFocus ? window.accent : "#d4d7de" }
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
                                ChoiceBox {
                                    Layout.fillWidth: true
                                    enabled: window.state.mediaEditable
                                    model: [window.t("自动"), "NVIDIA · NVENC / NVDEC", "AMD / Intel · VA-API"]
                                    currentIndex: ["auto", "nvidia", "vaapi"].indexOf(window.state.mediaBackend)
                                    onActivated: window.backend.setMedia(["auto", "nvidia", "vaapi"][currentIndex], window.state.mediaRenderNode)
                                    Accessible.name: window.t("媒体后端")
                                }
                                ChoiceBox {
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
                        BodyText { text: window.t("一个连接组包含一台主机和最多两台从机。主机显示配对码，从机选择主机后加入。") }
                        Card {
                            ColumnLayout {
                                width: parent.width; spacing: 12
                                Heading { text: window.t("本机角色") }
                                ChoiceBox {
                                    objectName: "pairingRole"
                                    Layout.fillWidth: true
                                    model: [window.t("请选择角色"), window.t("主机"), window.t("从机")]
                                    currentIndex: window.state.discovery.role === "host" ? 1 : window.state.discovery.role === "client" ? 2 : 0
                                    enabled: !window.state.busy && !window.state.transitioning
                                    onActivated: function(index) { if (index > 0) window.backend.setPairingRole(index === 1 ? "host" : "client") }
                                }
                                BodyText { text: window.state.discovery.role === "host" ? window.t("由本机管理连接组，等待从机加入。") : window.t("从机只能加入一个主机的连接组。") }
                                BodyText { visible: (window.state.discovery.count || 0) > 1; text: window.t("切换角色会退出当前连接组。") }
                            }
                        }
                        Card {
                            visible: window.state.discovery.role === "host"
                            ColumnLayout {
                                width: parent.width; spacing: 12
                                Heading { text: window.t("主机配对码") }
                                BodyText { text: window.state.discovery.name || "Viewflow" }
                                Label { visible: !!window.state.discovery.code; text: window.state.discovery.code || ""; font.pixelSize: 36; font.letterSpacing: 6; color: window.ink }
                                BodyText { visible: window.state.discovery.count >= 3; text: window.t("连接组已满，最多三台电脑。") }
                                Row {
                                    Layout.fillWidth: true; spacing: 8
                                    ActionButton { text: window.state.discovery.code ? window.t("更换配对码") : window.t("显示配对码"); enabled: window.state.discovery.count < 3 && !window.state.busy; onClicked: window.backend.showPairingCode() }
                                    ActionButton { visible: !!window.state.discovery.code; text: window.t("取消"); onClicked: window.backend.cancelPairingCode() }
                                }
                                BodyText { text: (window.state.discovery.addresses || []).join("\n"); font.pixelSize: 12 }
                            }
                        }
                        Heading { visible: !!window.state.discovery.groupID; text: window.t("当前连接组") + " · " + (window.state.discovery.count || 0) + "/3" }
                        Repeater {
                            model: window.state.discovery.members || []
                            delegate: Card {
                                required property var modelData
                                ColumnLayout {
                                    width: parent.width; spacing: 8
                                    Heading { text: modelData.name }
                                    BodyText { text: modelData.platform + " · " + (modelData.role === "host" ? window.t("主机") : window.t("从机")) + (modelData.local ? " · " + window.t("本机") : " · " + (modelData.online ? window.t("在线") : window.t("等待重连"))) }
                                    BodyText { visible: !!modelData.address; text: modelData.address || ""; font.pixelSize: 12 }
                                    SettingSwitch {
                                        visible: !modelData.local && !!modelData.options
                                        text: window.t("透明窗口")
                                        checked: !modelData.options || modelData.options.transparency !== false
                                        onToggled: window.backend.setConnectionOption(modelData.id, "transparency", checked)
                                    }
                                    SettingSwitch {
                                        visible: !modelData.local && !!modelData.options
                                        text: window.t("触控板 HID 转发")
                                        checked: !modelData.options || modelData.options.hid_forwarding !== false
                                        onToggled: window.backend.setConnectionOption(modelData.id, "hid_forwarding", checked)
                                    }
                                    ChoiceBox {
                                        visible: !modelData.local && !!modelData.options
                                        Layout.fillWidth: true
                                        objectName: "qualityMode"
                                        Accessible.name: window.t("画质与网络")
                                        model: [window.t("自动适应网络"), window.t("高画质（有线）"), window.t("省带宽（无线）")]
                                        currentIndex: ["auto", "high_quality", "save_bandwidth"].indexOf(modelData.options && modelData.options.quality_mode ? modelData.options.quality_mode : "auto")
                                        onActivated: window.backend.setQualityMode(modelData.id, ["auto", "high_quality", "save_bandwidth"][currentIndex])
                                    }
                                    ActionButton { visible: window.state.discovery.role === "host" && !modelData.local; text: window.t("移出连接组"); enabled: !window.state.busy; onClicked: window.backend.removeGroupMember(modelData.id) }
                                }
                            }
                        }
                        Row {
                            visible: !!window.state.discovery.groupID
                            Layout.fillWidth: true; spacing: 8
                            ConnectionIcon { symbol: "disconnect.svg"; description: window.t("断开连接"); enabled: !window.state.busy && !window.state.discovery.paused; onClicked: window.backend.disconnectGroup() }
                            ConnectionIcon { symbol: "reconnect.svg"; description: window.t("断开并重新连接"); enabled: !window.state.busy; onClicked: window.backend.reconnectGroup() }
                            ActionButton { text: window.state.discovery.role === "host" ? window.t("解散连接组") : window.t("退出连接组"); enabled: !window.state.busy && !window.state.transitioning; onClicked: window.backend.leaveGroup() }
                        }
                        ColumnLayout {
                            visible: window.state.discovery.role === "client" && !window.state.discovery.groupID
                            Layout.fillWidth: true; spacing: 12
                            Heading { text: window.t("附近的主机") }
                            BodyText { visible: !(window.state.discovery.machines || []).length; text: window.t("正在查找局域网中的主机。也可以在下方输入主机地址。") }
                            Repeater {
                                model: window.state.discovery.machines || []
                                delegate: Card {
                                    required property var modelData
                                    ColumnLayout {
                                        width: parent.width; spacing: 8
                                        Heading { text: modelData.name }
                                        BodyText { text: modelData.platform + " · " + modelData.address + " · " + modelData.count + "/3" }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            TextField { id: machineCode; placeholderText: window.t("主机的六位配对码"); maximumLength: 6; inputMethodHints: Qt.ImhDigitsOnly; Layout.fillWidth: true; Layout.minimumWidth: 80 }
                                            ActionButton { Layout.maximumWidth: 220; text: window.t("加入连接组"); primary: true; enabled: !window.state.busy && !window.state.transitioning && modelData.count < 3 && machineCode.text.length === 6; onClicked: window.backend.connectMachine(modelData.address, machineCode.text, modelData.id) }
                                        }
                                    }
                                }
                            }
                            Heading { text: window.t("手动输入主机地址") }
                            TextField { id: manualAddress; Layout.fillWidth: true; placeholderText: window.t("主机名或 IP 地址（可带端口）") }
                            RowLayout {
                                Layout.fillWidth: true
                                TextField { id: manualCode; Layout.fillWidth: true; Layout.minimumWidth: 80; placeholderText: window.t("主机的六位配对码"); maximumLength: 6; inputMethodHints: Qt.ImhDigitsOnly }
                                ActionButton { Layout.maximumWidth: 220; text: window.t("加入连接组"); primary: true; enabled: !window.state.busy && !window.state.transitioning && manualAddress.text.length > 0 && manualCode.text.length === 6; onClicked: window.backend.connectMachine(manualAddress.text, manualCode.text, "") }
                            }
                        }
                        BodyText { visible: !!window.state.discovery.warning; text: window.state.discovery.warning || "" }
                    }

                    DisplayLayout {
                        visible: window.page === 3
                        Layout.fillWidth: true
                        displays: window.state.discovery.displays || []
                        editable: window.state.discovery.role === "host" && !window.state.busy && !window.state.transitioning
                        translations: window.state.translations
                        onPositionChanged: function(identity,x,y) { window.backend.setDisplayPosition(identity,x,y) }
                    }

                    ColumnLayout {
                        visible: window.page === 4
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
