import importlib.util
from pathlib import Path
import tempfile
import unittest
import json
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('fusion',Path(__file__).parents[1]/'windows-fusion.py')
fusion=importlib.util.module_from_spec(spec);spec.loader.exec_module(fusion)

class Paths(unittest.TestCase):
    def test_start_uses_bar_session_and_anchor(self):
        instances=[{'instance':'desktop','wl_socket':'wayland-1'}, {'instance':'test','wl_socket':'wayland-2'}]
        clients=[{'mapped':True,'class':'ViewflowReverse-WindowsStart-1','address':'0x123','size':[500,600]}]
        monitors=[{'x':0,'y':0,'width':1920,'height':1080,'scale':1,'activeWorkspace':{'name':'3'}}]
        def output(command,**kwargs):
            if command[1]=='instances':return json.dumps(instances)
            self.assertEqual(kwargs['env']['HYPRLAND_INSTANCE_SIGNATURE'],'desktop')
            return json.dumps(clients if command[1]=='clients' else monitors)
        with patch.dict(fusion.os.environ,{'HYPRLAND_INSTANCE_SIGNATURE':'desktop'}), patch.object(fusion.subprocess,'check_output',side_effect=output), patch.object(fusion.subprocess,'run') as run:
            fusion.focus_start_menu([100,60])
            commands=[c.args[0][-1] for c in run.call_args_list]
            self.assertIn('workspace="3"',commands[0])
            self.assertIn('x=100,y=60',commands[1])
            self.assertIn('window.pin',commands[2])
            self.assertTrue(commands[3].startswith('hl.plugin.viewflow.focus_without_warp('))
    def test_real_file_and_url(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);file=root/'中文 $ report.txt';file.write_text('test')
            share={'root':directory,'unc':r'\\host\Home'}
            self.assertEqual(fusion.windows_path(str(file),share),r'\\host\Home\中文 $ report.txt')
            self.assertEqual(fusion.windows_path(file.as_uri(),share),fusion.windows_path(str(file),share))
    def test_mounted_subtree_uses_original_bridge(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cloud=root/'cloud';cloud.mkdir()
            original=cloud/'中文 report.docx';original.write_text('original')
            (root/'Downloads').symlink_to(cloud,target_is_directory=True)
            share={'root':str(root),'unc':r'\\host\Home','mounts':[{'root':str(cloud),'unc':r'\\host\Cloud'}]}
            self.assertEqual(fusion.windows_path(str(root/'Downloads'/original.name),share),r'\\host\Cloud\中文 report.docx')
            local=root/'local.docx';local.write_text('local')
            self.assertEqual(fusion.windows_path(str(local),share),r'\\host\Home\local.docx')
            # A mount override must not widen the selected sharing scope.
            share['root']=str(root/'Downloads')
            with self.assertRaises(ValueError):fusion.windows_path(str(local),share)

    def test_share_scope_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);shared=root/'shared';shared.mkdir();outside=root/'private';outside.write_text('test')
            (shared/'link').symlink_to(outside)
            share={'root':str(shared),'unc':r'\\host\Temp'}
            for path in [outside,shared/'link']:
                with self.assertRaises(ValueError):fusion.windows_path(str(path),share)
            bad=shared/'a:b';bad.write_text('test')
            with self.assertRaises(ValueError):fusion.windows_path(str(bad),share)
            with self.assertRaises(ValueError):fusion.windows_path('file://remote/share/x',share)

if __name__=='__main__':unittest.main()
