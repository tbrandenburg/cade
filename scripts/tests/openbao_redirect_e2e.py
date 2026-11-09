"""Real CLI redirect rejection, using an owned portless TLS redirect listener."""

import os
import tempfile
import time
import unittest
from pathlib import Path

from openbao_tls_fixture import Bao, BaoError, Instance, command


class OpenBaoRedirectTLS(unittest.TestCase):
    def test_password_request_never_follows_redirect(self) -> None:
        command("ss", "-ltn")
        with tempfile.TemporaryDirectory(
            prefix="cade-170-", dir="/tmp/opencode"
        ) as directory:
            instance = Instance(Path(directory))
            instance.start()
            try:
                binary = command(
                    "docker", "exec", instance.name, "sh", "-c", "command -v bao"
                ).strip()
                command(
                    "docker",
                    "cp",
                    instance.name + ":" + binary,
                    str(instance.directory / "bao"),
                )
            finally:
                instance.stop()
            configuration = instance.directory / "redirect.conf"
            configuration.write_text("""
pid /tmp/nginx.pid;
error_log /dev/stderr;
events {}
http {
  client_body_temp_path /tmp/client-body;
  proxy_temp_path /tmp/proxy;
  fastcgi_temp_path /tmp/fastcgi;
  uwsgi_temp_path /tmp/uwsgi;
  scgi_temp_path /tmp/scgi;
  access_log off;
  server {
    listen 127.0.0.1:8200 ssl;
    ssl_certificate /test/certs/openbao.crt;
    ssl_certificate_key /test/certs/openbao.key;
    access_log /test/tls.log;
    return 307 http://127.0.0.1:8201/capture;
  }
  server {
    listen 127.0.0.1:8201;
    access_log /test/sink.log;
    return 200 '{}';
  }
}
""")
            try:
                command(
                    "docker",
                    "run",
                    "-d",
                    "--name",
                    instance.name,
                    "--network",
                    "none",
                    "--user",
                    f"{os.getuid()}:{os.getgid()}",
                    "--cap-drop",
                    "ALL",
                    "--security-opt",
                    "no-new-privileges",
                    "--entrypoint",
                    "nginx",
                    "-e",
                    "BAO_DISABLE_REDIRECTS=false",
                    "-v",
                    f"{instance.directory}:/test",
                    "-v",
                    f"{instance.directory / 'bao'}:/usr/bin/bao:ro",
                    "nginx:1.27-alpine",
                    "-c",
                    "/test/redirect.conf",
                    "-g",
                    "daemon off;",
                )
                instance.select()
                # The certificate has the same in-container path as the real fixture.
                os.environ["BAO_CACERT"] = "/test/certs/openbao.crt"
                for _ in range(40):
                    if (instance.directory / "sink.log").exists():
                        break
                    time.sleep(0.1)
                self.assertTrue(
                    (instance.directory / "sink.log").exists(),
                    "Owned TLS redirect listener did not start",
                )
                with self.assertRaises(BaoError):
                    Bao("synthetic-test-token").write(
                        "auth/userpass/login/cade-operator",
                        {"password": "synthetic-test-password"},
                    )
                self.assertIn(
                    '"PUT /v1/auth/userpass/login/cade-operator HTTP/1.1" 307 ',
                    (instance.directory / "tls.log").read_text(),
                )
                self.assertEqual((instance.directory / "sink.log").read_text(), "")
                print(
                    "PASS verified-TLS password request refused redirect; "
                    "HTTP sink received zero requests"
                )
            finally:
                instance.stop()
