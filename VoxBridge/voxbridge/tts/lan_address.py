"""Find the Mac's physical LAN address without sending a network probe."""
from __future__ import annotations

import ipaddress
import re
import subprocess


class LANAddressUnavailable(RuntimeError):
    pass


_LAN_NETWORKS = tuple(ipaddress.ip_network(value) for value in (
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
))


def _command_output(command):
    try:
        return subprocess.run(command, capture_output=True, text=True,
                              timeout=2, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ''


def detect_lan_ipv4() -> str:
    """Prefer the default Ethernet/Wi-Fi interface; skip VPN and loopback."""
    route = _command_output(['/sbin/route', '-n', 'get', 'default'])
    preferred = re.search(r'^\s*interface:\s*(\S+)', route, re.M)
    interfaces = _command_output(['/sbin/ifconfig'])
    candidates = {}
    for block in re.split(r'\n(?=\S)', interfaces):
        header = re.match(r'((?:en|bridge)\d+):.*<([^>]+)>', block)
        if not header or not {'UP', 'RUNNING'}.issubset(header[2].split(',')):
            continue
        if re.search(r'status:\s*inactive', block):
            continue
        for value in re.findall(r'^\s+inet\s+(\S+)', block, re.M):
            try:
                address = ipaddress.IPv4Address(value)
            except ipaddress.AddressValueError:
                continue
            if any(address in network for network in _LAN_NETWORKS):
                candidates.setdefault(header[1], str(address))
    if preferred and preferred[1] in candidates:
        return candidates[preferred[1]]
    if candidates:
        return next(iter(candidates.values()))
    raise LANAddressUnavailable('未连接局域网：请连接 Wi-Fi 或以太网后刷新页面。')
