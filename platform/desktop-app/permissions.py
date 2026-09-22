"""Human-readable summaries of read-only checks, separate from raw diagnostics."""
from i18n import translate
from linux_setup import PLUGINS


def permission_rows(report, language):
    rows = []
    def add(title, status, detail, tone='neutral', **values):
        rows.append(dict(title=translate(title, language), status=translate(status, language),
                         detail=translate(detail, language, **values), tone=tone))
    if not report:
        return rows
    if report.get('platform') == 'windows':
        code = report.get('input_service_code')
        state = report.get('input_service_state')
        status = ('正在运行' if state == 4 else '已停止' if state == 1 else '已安装') if code == 0 else '未安装' if code == 1060 else '无法确认'
        add('锁屏输入服务', status, '仅操作 Windows 锁屏时需要此服务；普通会话不受影响。' if code in (0, 1060) else '请在诊断页查看服务查询详情。')
        add('原生触控板', '已内置', '系统 API 支持和真实手势效果仍需在此电脑确认。')
        return rows
    hypr = report.get('hyprland')
    hypr = hypr if isinstance(hypr, dict) else {}
    if hypr.get('commit') or hypr.get('version'):
        add('桌面会话', '已检测到', 'Hyprland ' + str(hypr.get('version', '')), 'good')
    else:
        add('桌面会话', '无法确认', '未连接到 Hyprland，请在 Hyprland 会话中打开应用。', 'warning')
    built = report.get('plugin_build')
    built = built if isinstance(built, dict) else {}
    if built.get('commit') and hypr.get('commit'):
        matches = built['commit'] == hypr['commit']
        add('插件版本', '版本匹配' if matches else '需要更新',
            '安装包插件与当前 Hyprland 构建匹配；是否加载需另行确认。' if matches else '请使用与当前 Hyprland 构建匹配的安装包。', 'good' if matches else 'warning')
    else:
        add('插件版本', '无法确认', '缺少构建信息，暂时无法比较插件版本。')
    plugins = report.get('plugins')
    if isinstance(plugins, list):
        names = {item.get('name') for item in plugins if isinstance(item, dict)}
        missing = [name for name in PLUGINS if name not in names]
        add('插件加载', '待加载' if missing else '已加载', ', '.join(missing or PLUGINS), 'warning' if missing else 'good')
    else:
        add('插件加载', '无法确认', '无法读取当前会话的插件列表。')
    devices = report.get('input_devices', [])
    readable = sum(bool(device.get('readable')) for device in devices)
    add('输入设备访问', ('可读取' if readable == len(devices) else '部分可读取' if readable else '需要设置') if devices else '未发现设备',
        '可读取 {readable} / {total} 个输入设备。请确认所选触控板在可读取的设备中。' if devices else '没有发现输入设备；使用原始触控板转发前请连接设备。',
        'good' if devices and readable == len(devices) else 'warning', readable=readable, total=len(devices))
    setup = report.get('linux_setup', {})
    if setup:
        installed = setup.get('packages', {})
        cached = setup.get('repository_versions', {})
        vendors = {device.get('vendor') for device in setup.get('gpu_devices', []) if device.get('driver') != 'vfio-pci'}
        packages = ['hyprland']
        if '0x10de' in vendors: packages.append('nvidia-utils')
        if '0x1002' in vendors: packages.extend(['mesa', 'libva'])
        if '0x8086' in vendors: packages.extend(['libva', 'intel-media-driver' if 'libva-intel-driver' not in installed else 'libva-intel-driver'])
        for package in dict.fromkeys(packages):
            add(package, '已安装' if package in installed else '未安装',
                '已安装：{installed}；仓库缓存：{available}', 'good' if package in installed else 'warning', installed=installed.get(package, '—'), available=cached.get(package, '—'))
        gpu = setup.get('nvidia_query', {})
        if gpu.get('code') == 0:
            add('NVIDIA 驱动', '可用', gpu.get('output', ''), 'good')
        elif '0x10de' in vendors and (setup.get('nvidia_kernel') or 'nvidia-utils' in installed):
            add('NVIDIA 驱动', '需要检查', '驱动已安装，但当前会话查询失败。请检查驱动与内核状态；更新后可能需要重启。', 'warning')
        elif '0x10de' in vendors:
            add('NVIDIA 驱动', '未就绪', '当前 GPU 组件需要 NVIDIA 驱动。安装前请确认显卡型号与内核。', 'warning')
        if vendors.intersection({'0x1002', '0x8086'}):
            add('AMD / Intel 编解码', '待硬件验证', 'VA-API 已接入媒体管线；依赖已安装不代表硬件链路可用，请运行合成媒体检查。', 'warning')
        add('系统与内核', '已检测到', setup.get('distro', '') + ' / ' + setup.get('kernel', ''), 'good')
    return rows
