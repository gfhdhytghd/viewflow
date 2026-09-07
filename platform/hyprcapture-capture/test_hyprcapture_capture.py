import json
import os
import stat
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import hyprcapture_capture as adapter


class HyprCaptureContractTests(unittest.TestCase):
    def private_file(self, path: Path, payload: bytes) -> None:
        path.write_bytes(payload)
        os.chmod(path, 0o600)

    def response(self, artifact: Path, address="0xabc"):
        return {"id": "session", "defaults": {"mode": "window", "windowBorder": "keep",
                "windowShadow": "keep", "windowBackground": "transparent"}, "monitors": [], "windows": [{
            "address": address, "artifactPath": str(artifact), "artifactWidth": 2, "artifactHeight": 1,
            "artifactTopDown": True,
            "visibleGeometry": {"x": 10, "y": 20, "width": 2, "height": 1},
            "fullGeometry": {"x": 9, "y": 19, "width": 4, "height": 3},
        }]}

    def test_request_has_contract_defaults(self):
        request = adapter.make_request("0xabc")
        self.assertEqual(request["mode"], "window")
        self.assertEqual(request["defaults"]["windowBackground"], "transparent")
        self.assertEqual(request["defaults"]["windowBorder"], "keep")
        self.assertEqual(request["defaults"]["windowShadow"], "keep")

    def test_rejects_changed_decoration_policy(self):
        root = adapter._private_root()
        with tempfile.TemporaryDirectory(dir=root) as directory:
            response = Path(directory) / "response.json"
            for key, value in (("windowBorder", "remove"), ("windowShadow", "remove"),
                               ("windowBackground", "real")):
                payload = self.response(Path(directory) / "window.rgba")
                payload["defaults"][key] = value
                self.private_file(response, json.dumps(payload).encode())
                with self.assertRaisesRegex(adapter.ContractError, "capture policy"):
                    adapter.read_response(response, "0xabc")

    def test_response_import_preserves_geometries_and_premultiplies(self):
        root = adapter._private_root()
        with tempfile.TemporaryDirectory(dir=root) as directory:
            directory = Path(directory)
            artifact, response, output = directory / "window.rgba", directory / "response.json", directory / "out.vfbg"
            self.private_file(artifact, bytes((200, 100, 50, 128, 1, 2, 3, 255)))
            self.private_file(response, json.dumps(self.response(artifact)).encode())
            info = adapter.import_response(response, "0xabc", output)
            self.assertEqual(output.read_bytes(), struct.pack(">4sBBHIII", b"VFBG", 1, 1, 0, 2, 1, 8) + bytes((25, 50, 100, 128, 3, 2, 1, 255)))
            self.assertEqual(info["visibleGeometry"]["x"], 10.0)
            self.assertEqual(info["fullGeometry"]["width"], 4.0)
            self.assertEqual(info["pixelFormat"], "VFBG-premultiplied-BGRA")

    def test_rejects_identity_mismatch_and_nonprivate_artifact(self):
        root = adapter._private_root()
        with tempfile.TemporaryDirectory(dir=root) as directory:
            directory = Path(directory)
            artifact, response = directory / "window.rgba", directory / "response.json"
            self.private_file(artifact, b"\0" * 8)
            self.private_file(response, json.dumps(self.response(artifact, "0xother")).encode())
            with self.assertRaisesRegex(adapter.ContractError, "identity"):
                adapter.read_response(response, "0xabc")
            self.private_file(response, json.dumps(self.response(Path("/tmp/not-private.rgba"))).encode())
            with self.assertRaises(adapter.ContractError):
                adapter.import_response(response, "0xabc", directory / "out")

    def test_rejects_group_writable_response(self):
        root = adapter._private_root()
        with tempfile.TemporaryDirectory(dir=root) as directory:
            directory = Path(directory)
            artifact, response = directory / "window.rgba", directory / "response.json"
            self.private_file(artifact, b"\0" * 8)
            self.private_file(response, json.dumps(self.response(artifact)).encode())
            os.chmod(response, stat.S_IRUSR | stat.S_IWUSR | stat.S_IWGRP)
            with self.assertRaises(adapter.ContractError):
                adapter.read_response(response, "0xabc")

    def test_refuses_to_replace_existing_output(self):
        root = adapter._private_root()
        with tempfile.TemporaryDirectory(dir=root) as directory:
            directory = Path(directory)
            artifact, response, output = directory / "window.rgba", directory / "response.json", directory / "out.vfbg"
            self.private_file(artifact, b"\0" * 8)
            self.private_file(response, json.dumps(self.response(artifact)).encode())
            output.write_bytes(b"keep")
            with self.assertRaisesRegex(adapter.ContractError, "already exists"):
                adapter.import_response(response, "0xabc", output)
            self.assertEqual(output.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
