import base64, hashlib, hmac, json, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zoom_token  # noqa: E402


def decode(part):
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


class ZoomTokenTest(unittest.TestCase):
    def test_claims_and_signature(self):
        token = zoom_token.make_token("KEY", "SECRET", "room-1", 1, "host", 7200, now=1_000_000)
        header, payload, sig = token.split(".")
        claims = decode(payload)
        self.assertEqual(decode(header), {"alg": "HS256", "typ": "JWT"})
        self.assertEqual(claims["app_key"], "KEY")
        self.assertEqual(claims["tpc"], "room-1")
        self.assertEqual(claims["role_type"], 1)
        self.assertEqual(claims["version"], 1)
        self.assertEqual(claims["exp"] - claims["iat"], 7200)
        expected = hmac.new(b"SECRET", f"{header}.{payload}".encode(), hashlib.sha256).digest()
        self.assertEqual(sig, base64.urlsafe_b64encode(expected).rstrip(b"=").decode())

    def test_lifetime_clamped_to_zoom_window(self):
        short = decode(zoom_token.make_token("K", "S", "r", 0, lifetime=60).split(".")[1])
        long = decode(zoom_token.make_token("K", "S", "r", 0, lifetime=10**7).split(".")[1])
        self.assertEqual(short["exp"] - short["iat"], 1800)
        self.assertEqual(long["exp"] - long["iat"], 48 * 3600)

    def test_rejects_bad_role(self):
        with self.assertRaises(ValueError):
            zoom_token.make_token("K", "S", "r", 2)


if __name__ == "__main__":
    unittest.main()
