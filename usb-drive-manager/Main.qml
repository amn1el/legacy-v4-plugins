import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
    id: root

    property var pluginApi: null
    property var devices: []
    property bool loading: false
    property int mountedCount: 0
    property bool pendingAutoMount: false

    // ===== SETTINGS SHORTCUTS =====
    readonly property bool autoMount:          pluginApi?.pluginSettings?.autoMount          ?? false
    readonly property string fileBrowser:      pluginApi?.pluginSettings?.fileBrowser        || "yazi"
    readonly property string terminalCommand:  pluginApi?.pluginSettings?.terminalCommand    || "kitty"
    readonly property bool showNotifications:  pluginApi?.pluginSettings?.showNotifications  ?? true
    readonly property bool hideWhenEmpty:      pluginApi?.pluginSettings?.hideWhenEmpty      ?? false

    Component.onCompleted: refreshDevices()

    IpcHandler {
        target: "plugin:usb-drive-manager"

        function refresh() {
            root.refreshDevices()
        }
        function unmountAll() {
            root.unmountAll()
        }
    }

    // ===== DEVICE MONITORING =====
    Process {
        id: deviceWatcher
        command: ["udevadm", "monitor", "--subsystem-match=block", "--property"]
        running: true

        stdout: SplitParser {
            onRead: line => {
                if (line.startsWith("ACTION=add")) {
                    root.pendingAutoMount = true
                    refreshDebounce.restart()
                } else if (line.startsWith("ACTION=remove") || line.startsWith("ACTION=change")) {
                    refreshDebounce.restart()
                }
            }
        }
        onExited: exitCode => { if (exitCode !== 0) restartWatcherTimer.start() }
    }

    Timer {
        id: restartWatcherTimer
        interval: 3000
        onTriggered: deviceWatcher.running = true
    }

    Timer {
        id: refreshDebounce
        interval: 800
        onTriggered: refreshDevices()
    }

    // ===== DEVICE ENUMERATION =====
    Process {
        id: deviceQuery
        command: [
            "lsblk", "-J",
            "-o", "NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,HOTPLUG,TRAN,MODEL,VENDOR,RM,PATH,PKNAME"
        ]
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}

        onExited: exitCode => {
            root.loading = false
            if (exitCode === 0) {
                try {
                    const data = JSON.parse(String(stdout.text))
                    root.devices = internal.parseDevices(data.blockdevices || [])

                    if (root.autoMount && root.pendingAutoMount) {
                        root.autoMountNewDevices()
                        root.pendingAutoMount = false
                    }

                    root.devicesChanged()
                } catch (e) {
                    console.warn("[usb-drive-manager] Failed to parse lsblk output:", e)
                }
            }
        }
    }

    Process {
        id: dfQuery
        command: ["df", "--output=target,pcent,used,avail", "-h"]
        running: false
        stdout: StdioCollector {}
        onExited: exitCode => {
            if (exitCode === 0) {
                internal.parseDfOutput(String(stdout.text))
            }
        }
    }

    // ===== ACTION PROCESSES =====
    Process {
        id: mountProc
        property string devicePath: ""
        property string deviceLabel: ""
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: exitCode => {
            if (exitCode === 0 && root.showNotifications) {
                ToastService.showNotice(pluginApi?.tr("notifications.mounted"), mountProc.deviceLabel || mountProc.devicePath)
            } else if (exitCode !== 0) {
                ToastService.showError(pluginApi?.tr("notifications.mount-failed"), String(stderr.text).trim() || mountProc.devicePath)
            }
            refreshDebounce.restart()
        }
    }

    Process {
        id: unmountProc
        property string devicePath: ""
        property string deviceLabel: ""
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: exitCode => {
            if (exitCode === 0 && root.showNotifications) {
                ToastService.showNotice(pluginApi?.tr("notifications.unmounted"), unmountProc.deviceLabel || unmountProc.devicePath)
            } else if (exitCode !== 0) {
                ToastService.showError(pluginApi?.tr("notifications.unmount-failed"), String(stderr.text).trim() || unmountProc.devicePath)
            }
            refreshDebounce.restart()
        }
    }

    Process {
        id: ejectProc
        property string devicePath: ""
        property string deviceLabel: ""
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: exitCode => {
            if (exitCode === 0 && root.showNotifications) {
                ToastService.showNotice(pluginApi?.tr("notifications.ejected"), ejectProc.deviceLabel || ejectProc.devicePath)
            } else if (exitCode !== 0) {
                ToastService.showError(pluginApi?.tr("notifications.eject-failed"), String(stderr.text).trim() || ejectProc.devicePath)
            }
            refreshDebounce.restart()
        }
    }

    // ===== INTERNAL HELPERS =====
    QtObject {
        id: internal
        function parseDevices(blockdevices) {
            const result = []
            let newMountedCount = 0

            function processDevice(dev, parentPath, parentIsUsb) {
                const isUsb = parentIsUsb || dev.tran === "usb" || dev.hotplug === true || dev.hotplug === "1"
                const isRemovable = dev.rm === true || dev.rm === "1"

                if (dev.children && dev.children.length > 0) {
                    for (const child of dev.children) {
                        processDevice(child, dev.path || ("/dev/" + dev.name), isUsb)
                    }
                }

                const hasFs = dev.fstype && dev.fstype.length > 0
                if ((isUsb || isRemovable) && hasFs) {
                    const mountpoint = dev.mountpoint || ""
                    const isMounted = mountpoint.length > 0
                    
                    if (isMounted) newMountedCount++

                    result.push({
                        name:        dev.name || "",
                        path:        dev.path || ("/dev/" + dev.name),
                        parentPath:  parentPath || dev.path || ("/dev/" + dev.name),
                        label:       dev.label || dev.name || "",
                        size:        dev.size || "",
                        fstype:      dev.fstype || "",
                        mountpoint:  mountpoint,
                        isMounted:   isMounted,
                        model:       dev.model || "",
                        vendor:      dev.vendor ? dev.vendor.trim() : "",
                        usedPercent: 0,
                        usedSize:    "",
                        freeSize:    ""
                    })
                }
            }

            for (const dev of blockdevices) processDevice(dev, null, false)
            root.mountedCount = newMountedCount
            return result
        }

        function parseDfOutput(text) {
            const lines = text.split("\n")
            const usageMap = {}
            for (let i = 1; i < lines.length; i++) {
                const parts = lines[i].trim().split(/\s+/)
                if (parts.length >= 4) {
                    usageMap[parts[0]] = { pcent: parseInt(parts[1]) || 0, used: parts[2] || "", avail: parts[3] || "" }
                }
            }
            root.devices = root.devices.map(dev => {
                if (dev.isMounted && usageMap[dev.mountpoint]) {
                    return Object.assign({}, dev, {
                        usedPercent: usageMap[dev.mountpoint].pcent,
                        usedSize:    usageMap[dev.mountpoint].used,
                        freeSize:    usageMap[dev.mountpoint].avail
                    })
                }
                return dev
            })
            root.devicesChanged()
        }
    }

    // ===== PUBLIC API =====
    function refreshDevices() {
        root.loading = true
        deviceQuery.running = false
        deviceQuery.running = true
        dfTimer.restart()
    }

    Timer {
        id: dfTimer
        interval: 1200
        onTriggered: { dfQuery.running = false; dfQuery.running = true }
    }

    function mountDevice(devicePath, deviceLabel) {
        if (mountProc.running) return
        mountProc.devicePath = devicePath
        mountProc.deviceLabel = deviceLabel
        mountProc.command = ["udisksctl", "mount", "-b", devicePath]
        mountProc.running = true
    }

    function unmountDevice(devicePath, deviceLabel) {
        if (unmountProc.running) return
        unmountProc.devicePath = devicePath
        unmountProc.deviceLabel = deviceLabel
        unmountProc.command = ["udisksctl", "unmount", "-b", devicePath]
        unmountProc.running = true
    }

    function ejectDevice(devicePath, parentPath, deviceLabel) {
        const target = parentPath || devicePath
        if (ejectProc.running) return
        ejectProc.devicePath = target
        ejectProc.deviceLabel = deviceLabel
        ejectProc.command = ["sh", "-c", "udisksctl unmount -b " + devicePath + " 2>/dev/null; udisksctl power-off -b " + target]
        ejectProc.running = true
    }

    function openInFileBrowser(mountpoint) {
        const browser = root.fileBrowser || "yazi"
        if (browser === "yazi" || browser === "ranger" || browser === "lf" || browser === "nnn") {
            const term = root.terminalCommand || "kitty"
            const termLower = term.toLowerCase()
            const flag = (termLower.indexOf("ptyxis") !== -1 || termLower.indexOf("gnome-terminal") !== -1 || termLower.indexOf("wezterm") !== -1) ? "--" : "-e"
            Quickshell.execDetached([term, flag, browser, mountpoint])
        } else {
            Quickshell.execDetached([browser, mountpoint])
        }
    }

    function unmountAll() {
        for (let i = 0; i < devices.length; i++) {
            if (devices[i].isMounted) Quickshell.execDetached(["udisksctl", "unmount", "-b", devices[i].path])
        }
        if (root.showNotifications) ToastService.showNotice(pluginApi?.tr("notifications.unmount-all"))
        refreshDebounce.restart()
    }

    function ejectAll() {
        const ejected = []
        for (let i = 0; i < devices.length; i++) {
            const dev = devices[i]
            const parent = dev.parentPath || dev.path
            if (!ejected.includes(parent)) {
                ejected.push(parent)
                Quickshell.execDetached(["sh", "-c", "udisksctl unmount -b " + dev.path + " 2>/dev/null; udisksctl power-off -b " + parent])
            }
        }
        if (root.showNotifications) ToastService.showNotice(pluginApi?.tr("notifications.eject-all"))
        refreshDebounce.restart()
    }

    function autoMountNewDevices() {
        for (let i = 0; i < devices.length; i++) {
            if (!devices[i].isMounted && devices[i].fstype) {
                mountDevice(devices[i].path, devices[i].label)
            }
        }
    }

    function buildTooltip() {
        if (mountedCount === 0) {
            return pluginApi?.tr("bar.tooltip-empty")
        }
        return pluginApi?.tr("bar.tooltip-count")?.replace("%1", mountedCount)
    }
}