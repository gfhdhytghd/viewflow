#!/usr/bin/env python3
"""Build a per-user x64 MSI from a complete Viewflow application using WiX 4."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET

NS = 'http://wixtoolset.org/schemas/v4/wxs'
ET.register_namespace('', NS)
UPGRADE_CODE = '3B468C57-A897-48A2-8E1A-A31CB04555DF'


def element(parent, tag, **attributes):
    return ET.SubElement(parent, '{' + NS + '}' + tag, attributes)


def identifier(prefix, path):
    return prefix + hashlib.sha256(path.encode()).hexdigest()[:24]


def author(payload, version):
    if not (payload / 'Viewflow.exe').is_file() or not (payload / 'bundle-manifest.json').is_file():
        raise ValueError('expected a complete Viewflow application directory')
    root = ET.Element('{' + NS + '}Wix')
    package = element(root, 'Package', Name='Viewflow', Manufacturer='Viewflow',
                      Version=version, UpgradeCode=UPGRADE_CODE, Scope='perUser', Language='1033')
    element(package, 'MajorUpgrade', DowngradeErrorMessage='A newer version of Viewflow is already installed.')
    element(package, 'MediaTemplate', EmbedCab='yes', CompressionLevel='high')
    element(package, 'Property', Id='ARPNOMODIFY', Value='1')
    local = element(package, 'StandardDirectory', Id='LocalAppDataFolder')
    programs = element(local, 'Directory', Id='ProgramsFolder', Name='Programs')
    install = element(programs, 'Directory', Id='INSTALLFOLDER', Name='Viewflow')
    menu = element(package, 'StandardDirectory', Id='ProgramMenuFolder')
    shortcut_dir = element(menu, 'Directory', Id='ViewflowMenu', Name='Viewflow')
    feature = element(package, 'Feature', Id='Main', Title='Viewflow', Level='1')
    directories = {Path('.'): install}
    for path in sorted(payload.rglob('*')):
        rel = path.relative_to(payload)
        if path.is_symlink():
            raise ValueError(f'symlinks are not supported: {rel}')
        if path.is_dir():
            directories[rel] = element(directories[rel.parent], 'Directory',
                                       Id=identifier('D', rel.as_posix()), Name=path.name)
            continue
        key = rel.as_posix()
        component_id = identifier('C', key)
        component = element(directories[rel.parent], 'Component', Id=component_id,
                            Guid=str(uuid.uuid5(uuid.UUID(UPGRADE_CODE), key)))
        element(component, 'RegistryValue', Root='HKCU', Key='Software\\Viewflow\\Installer',
                Name=component_id, Type='integer', Value='1', KeyPath='yes')
        element(component, 'File', Id=identifier('F', key), Source=str(path), Name=path.name)
        element(feature, 'ComponentRef', Id=component_id)
    # Registry key paths and explicit folder cleanup support a non-elevated install.
    for rel, directory in directories.items():
        key = rel.as_posix()
        component_id = identifier('R', key)
        component = element(directory, 'Component', Id=component_id, Guid='*')
        element(component, 'RegistryValue', Root='HKCU', Key='Software\\Viewflow\\Installer',
                Name=component_id, Type='integer', Value='1', KeyPath='yes')
        element(component, 'RemoveFolder', Id=identifier('Remove', key), On='uninstall')
        element(feature, 'ComponentRef', Id=component_id)
    component = element(programs, 'Component', Id='ProgramsFolderCleanup', Guid='*')
    element(component, 'RegistryValue', Root='HKCU', Key='Software\\Viewflow\\Installer',
            Name='ProgramsFolderCleanup', Type='integer', Value='1', KeyPath='yes')
    element(component, 'RemoveFolder', Id='RemoveProgramsFolder', On='uninstall')
    element(feature, 'ComponentRef', Id='ProgramsFolderCleanup')
    component = element(shortcut_dir, 'Component', Id='StartMenuShortcut', Guid='*')
    element(component, 'RegistryValue', Root='HKCU', Key='Software\\Viewflow\\Installer',
            Name='StartMenuShortcut', Type='integer', Value='1', KeyPath='yes')
    element(component, 'Shortcut', Id='LaunchViewflow', Name='Viewflow',
            Target='[INSTALLFOLDER]Viewflow.exe', WorkingDirectory='INSTALLFOLDER')
    element(component, 'RemoveFolder', Id='RemoveViewflowMenu', On='uninstall')
    element(feature, 'ComponentRef', Id='StartMenuShortcut')
    return ET.ElementTree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', default='0.1.0')
    parser.add_argument('--wix', default='wix')
    args = parser.parse_args()
    destination = args.output.resolve()
    if destination.exists():
        parser.error('output already exists')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='viewflow-msi-') as work:
        source = Path(work) / 'Viewflow.wxs'
        author(args.app.resolve(), args.version).write(source, encoding='utf-8', xml_declaration=True)
        subprocess.run([args.wix, 'build', '-arch', 'x64', '-o', str(destination), str(source)], check=True)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix('.msi.sha256').write_text(f'{digest}  {destination.name}\n')


if __name__ == '__main__':
    main()
