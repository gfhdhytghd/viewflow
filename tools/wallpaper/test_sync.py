import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image
from sync import discover, render, synchronize, quote


class WallpaperTest(unittest.TestCase):
    def test_provider_monitor_selection_and_spaces(self):
        text = ': DP-4: 3072x1728, scale: 2, currently displaying: image: /a b/x.jpg\n: HEADLESS-6: 1920x1200, scale: 2, currently displaying: color: 000000'
        self.assertEqual(discover(text, 'DP-4'), ('image', '/a b/x.jpg'))
        self.assertEqual(discover(text, 'HEADLESS-6'), ('color', '000000'))
        with self.assertRaises(ValueError):
            discover(text, 'DP-40')

    def test_center_crop_preserves_geometry(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'source.png'
            image = Image.new('RGB', (12, 4), 'red')
            for x in range(4, 8):
                for y in range(4):
                    image.putpixel((x, y), (0, 255, 0))
            image.save(path)
            result = Image.open(io.BytesIO(render('image', path, (4, 4))))
            self.assertEqual(result.size, (4, 4))
            self.assertEqual(result.getpixel((0, 0)), (0, 255, 0))
            self.assertEqual(result.getpixel((3, 3)), (0, 255, 0))

    def test_no_repeat_upload_and_order(self):
        with tempfile.TemporaryDirectory() as folder:
            config = dict(host='host', remote_root='C:/wallpaper', monitor='DP-4', rect=[-4, -2, 0, 2])
            events = []
            def command(args, **kwargs):
                events.append(args)
                return b'DP-4: 4x4, scale: 1, currently displaying: color: 123456'
            def ps(config, script):
                events.append(script)
                return b''
            with patch('sync.run', side_effect=command), patch('sync.powershell', side_effect=ps):
                previous = synchronize(config, Path(folder), None)
                count = len([e for e in events if isinstance(e, list) and e[0] == 'scp'])
                synchronize(config, Path(folder), previous)
                self.assertEqual(count, 2)
                self.assertEqual(len([e for e in events if isinstance(e, list) and e[0] == 'scp']), count)
                image_at = next(i for i,e in enumerate(events) if isinstance(e, list) and e[0] == 'scp' and e[-1].endswith('.png'))
                publish_at = next(i for i,e in enumerate(events) if isinstance(e,str) and '[PublishWallpaper]::Move' in e)
                self.assertLess(image_at, publish_at)

    def test_ps_path_quoting(self):
        self.assertEqual(quote("C:/a'b/$x.png"), "'C:/a''b/$x.png'")


if __name__ == '__main__':
    unittest.main()
