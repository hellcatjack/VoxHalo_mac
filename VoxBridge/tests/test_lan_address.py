from types import SimpleNamespace

import pytest

from voxbridge.tts import lan_address


INTERFACES = '''lo0: flags=8049<UP,LOOPBACK,RUNNING> mtu 16384
    inet 127.0.0.1 netmask 0xff000000
utun0: flags=8051<UP,POINTOPOINT,RUNNING> mtu 1380
    inet 10.9.0.2 netmask 0xffffffff
en3: flags=8863<UP,BROADCAST,RUNNING> mtu 1500
    inet 192.168.50.20 netmask 0xffffff00
    status: active
en0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500
    inet 192.168.1.253 netmask 0xffffff00
    status: active
'''


def fake_network(monkeypatch, route, interfaces=INTERFACES):
    def run(command, **kwargs):
        assert kwargs['timeout'] <= 2
        return SimpleNamespace(stdout=route if command[0].endswith('/route') else interfaces)
    monkeypatch.setattr(lan_address.subprocess, 'run', run)


def test_prefers_default_physical_interface(monkeypatch):
    fake_network(monkeypatch, 'interface: en0\n')
    assert lan_address.detect_lan_ipv4() == '192.168.1.253'


def test_vpn_default_uses_physical_lan_not_tunnel(monkeypatch):
    fake_network(monkeypatch, 'interface: utun0\n')
    assert lan_address.detect_lan_ipv4() == '192.168.50.20'


def test_no_default_route_still_supports_lan_without_internet(monkeypatch):
    fake_network(monkeypatch, '')
    assert lan_address.detect_lan_ipv4() == '192.168.50.20'


def test_does_not_advertise_inactive_loopback_or_self_assigned_ip(monkeypatch):
    fake_network(monkeypatch, 'interface: en0\n', INTERFACES.replace(
        '192.168.50.20', '169.254.1.2').replace('192.168.1.253', '0.0.0.0'))
    with pytest.raises(lan_address.LANAddressUnavailable):
        lan_address.detect_lan_ipv4()


def test_redetects_ip_after_network_change(monkeypatch):
    fake_network(monkeypatch, 'interface: en0\n')
    assert lan_address.detect_lan_ipv4() == '192.168.1.253'
    fake_network(monkeypatch, 'interface: en0\n', INTERFACES.replace('192.168.1.253', '192.168.1.99'))
    assert lan_address.detect_lan_ipv4() == '192.168.1.99'


def test_inactive_default_interface_is_not_advertised(monkeypatch):
    fake_network(monkeypatch, 'interface: en0\n', INTERFACES.rsplit('status: active', 1)[0] + 'status: inactive\n')
    assert lan_address.detect_lan_ipv4() == '192.168.50.20'


def test_os_command_failure_never_falls_back_to_loopback(monkeypatch):
    def fail(*args, **kwargs):
        raise OSError('interface inspection unavailable')
    monkeypatch.setattr(lan_address.subprocess, 'run', fail)
    with pytest.raises(lan_address.LANAddressUnavailable):
        lan_address.detect_lan_ipv4()
