"""对真实 python-strm 服务端复现「切档不生效」并验证客户端选档逻辑。

模拟 Dart 侧 StrmApiClient.resolvePlaybackUrl 的三步：抓服务端下发的清单 →
按 /hls/{resolution} 定位目标档位 → 得到实际播放地址；直链档位则跟随同源 302
把 resolution 补回去。用于在改客户端之后确认「每个档位真的解析出不同的流」。
"""

import re
import sys
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:8095"
UA = "jellfin-flutter/1.0"
STREAM_INF = "#EXT-X-STREAM-INF:"


def get(url, follow=False):
    """返回 (状态码, 响应头, 文本)；follow=False 时不跟随重定向。

    响应头保留 email.Message 形式：uvicorn 下发的是小写 `location`，转成普通
    dict 再按名字取会因大小写不一致而漏读（曾据此得出过错误的验证结论）。
    """

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    handlers = [] if follow else [NoRedirect()]
    opener = urllib.request.build_opener(*handlers)
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with opener.open(request, timeout=30) as response:
            return response.status, response.headers, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.headers, exc.read().decode("utf-8", "replace")


def variants(playlist):
    """主清单 → [(属性行, URI)]。"""
    lines = [line.strip() for line in playlist.splitlines()]
    found = []
    for index, line in enumerate(lines):
        if not line.startswith(STREAM_INF):
            continue
        for uri in lines[index + 1:]:
            if uri and not uri.startswith("#"):
                found.append((line[len(STREAM_INF):], uri))
                break
    return found


def resolve(cloud, file_id, resolution):
    """复现客户端选档，返回 (实际播放地址, 钉住的 hls-bitrate 或 None)。"""
    url = f"{BASE}/api/v1/strm/play/{cloud}/{file_id}?resolution={resolution}"
    status, headers, body = get(url)
    if 300 <= status < 400:
        location = headers.get("location", "")
        target = urllib.parse.urlparse(urllib.parse.urljoin(url, location))
        origin = urllib.parse.urlparse(url)
        if (target.scheme, target.hostname, target.port) != (origin.scheme, origin.hostname, origin.port):
            return url, None  # 跨源 CDN：留给播放器自己换
        query = dict(urllib.parse.parse_qsl(target.query))
        query["resolution"] = resolution
        return target._replace(query=urllib.parse.urlencode(query)).geturl(), None
    if STREAM_INF not in body:
        return url, None
    found = variants(body)
    if len(found) < 2:
        return url, None
    slug = re.compile(rf"/hls/{re.escape(resolution)}(?:[/?]|$)")
    for attributes, uri in found:
        if slug.search(uri):
            if "#EXT-X-MEDIA:TYPE=AUDIO" in body:
                bandwidth = re.search(r"BANDWIDTH=(\d+)", attributes)
                return url, int(bandwidth.group(1)) if bandwidth else None
            return urllib.parse.urljoin(url, uri), None
    return url, None


def landing(url):
    """把地址推进到「能区分档位的落地标识」：直链跟随到 CDN，取路径。

    直链档位的判定必须看最终落到哪条流上——修复前四个档位的 URL 各不相同，却都 302
    到同一个不带档位的内部路由，最终同一条流。只比中间地址会得出假 PASS。
    """
    status, headers, _ = get(url)
    hops = 0
    while 300 <= status < 400 and hops < 4:
        location = headers.get("location") or ""
        if not location:
            break
        url = urllib.parse.urljoin(url, location)
        hops += 1
        if urllib.parse.urlparse(url).hostname not in {"127.0.0.1", "localhost"}:
            break
        status, headers, _ = get(url)
    parsed = urllib.parse.urlparse(url)
    return f"{parsed.hostname}{parsed.path}"


def main():
    cloud, file_id = sys.argv[1], sys.argv[2]
    resolutions = sys.argv[3].split(",")

    print(f"== 服务端下发形态（{cloud}/{file_id}）==")
    for resolution in resolutions:
        status, headers, body = get(
            f"{BASE}/api/v1/strm/play/{cloud}/{file_id}?resolution={resolution}")
        if 300 <= status < 400:
            shape = f"{status} -> {(headers.get('location') or '')[:76]}"
        else:
            shape = f"{status} 主清单变体数={len(variants(body))}"
        print(f"  resolution={resolution:6s} {shape}")

    print("== 客户端选档后的实际播放地址 ==")
    resolved = {}
    for resolution in resolutions:
        url, bitrate = resolve(cloud, file_id, resolution)
        resolved[resolution] = (url, bitrate)
        pin = f" [hls-bitrate={bitrate}]" if bitrate else ""
        print(f"  resolution={resolution:6s} -> {url[:88]}{pin}")

    print("== 落地流（直链跟随到 CDN 后的路径）==")
    targets = {}
    for resolution, (url, bitrate) in resolved.items():
        target = f"{landing(url)}|{bitrate or ''}"
        targets[resolution] = target
        print(f"  resolution={resolution:6s} -> {target[:96]}")

    unique = len(set(targets.values()))
    print(f"== 判定：{len(targets)} 个档位落到 {unique} 条不同的流 ==")
    print("PASS：每个档位都播各自的流" if unique == len(targets)
          else "FAIL：仍有档位落到同一条流上")


if __name__ == "__main__":
    main()
